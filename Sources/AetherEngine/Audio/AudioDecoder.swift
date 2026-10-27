import Foundation
import CoreMedia
import CoreAudio
import AudioToolbox
import AetherLibavformat
import AetherLibavcodec
import AetherLibavutil
import AetherLibswresample

/// FFmpeg software audio decoder: compressed AVPackets -> multichannel interleaved Float32 PCM in CMSampleBuffers
/// for AVSampleBufferAudioRenderer. Uses libswresample to interleaved Float32 at source rate/channels (up to 7.1)
/// with proper AudioChannelLayout. Non-Atmos tracks only; EAC3+JOC Atmos passes through AVPlayer.
final class AudioDecoder: @unchecked Sendable {

    private var codecContext: UnsafeMutablePointer<AVCodecContext>?

    /// Serializes decode (demux thread) against flush/close (main actor). Without it a MainActor
    /// avcodec_flush_buffers could race an in-flight avcodec_send_packet on the same context (UB).
    /// Mirrors SoftwareVideoDecoder's lock discipline.
    private let stateLock = NSLock()
    private var swrContext: OpaquePointer?
    private var audioFormatDescription: CMAudioFormatDescription?

    /// Source stream time base for PTS conversion.
    private var timeBase: AVRational = AVRational(num: 1, den: 90000)

    /// TrueHD/MLP/lossless emit ~40-sample frames (0.83ms @48kHz); feeding 1200+ tiny CMSampleBuffers/sec makes
    /// AVSampleBufferAudioRenderer accept them then silently drop multichannel output. Coalesce to >= this many
    /// samples before building a buffer (~47 buffers/sec at ~21ms each, which the renderer handles).
    private static let minSamplesPerBuffer = 1024

    private var pendingBytes = Data()
    private var pendingSampleCount: Int = 0
    /// Where the pending buffer's first sample plays, and where the sample after the last one taken
    /// goes, in source frames at `sampleRate`: positions on the stream's grid, so consecutive buffers
    /// abut to the sample (#89: a buffer stamped with its container-rounded time left a gap or overlap
    /// at every frame of a non-integer-millisecond length, 1536-sample AC-3 at 44.1 kHz).
    private var pendingStart: Int64?
    private var nextPosition: Int64?

    /// The stream's frames on its lattice from its first coded frame (`SourceGrid`), built at the first
    /// frame from the stream's start and codec; `runFrames` counts what the decoder produced in the
    /// current run, the frame being placed included.
    private var grid: SourceGrid?
    private var sourceStart: Int64?
    private var sourceParameters: UnsafeMutablePointer<AVCodecParameters>?
    private var runFrames: Int64 = 0
    /// The decoder's count broke (a packet it refused, a flush): the next frame starts a new run.
    private var runBreakPending = false
    /// Decoded frames dropped because nothing yet said where they play.
    private(set) var framesDroppedUnplaced = 0
    private var reportedNoSourceStart = false

    #if DEBUG
    private var _loggedZeroConvert = false
    #endif

    /// Input parameters the current `swrContext` was built for (#452). `decode()`/`drain()` compare
    /// each frame against these and rebuild on a mid-stream change: a live splice can swap the
    /// stream's audio configuration (5.1 <-> stereo at a program boundary), and a context built for
    /// more input planes than the frame carries reads a NULL plane inside swr_convert.
    private var configuredInput = ResamplerInputParameters()

    private(set) var sampleRate: Int32 = 0
    private(set) var channels: Int32 = 0
    /// The order the resampler writes and the tag stamped on it (see `ResamplerOutput`).
    private var output = ResamplerOutput(channels: 2)
    /// Samples still to drop from the start of the next converted frames (an overlap).
    private var pendingTrimSamples = 0
    /// Frames placed away from where the count said, for tests and diagnostics.
    private(set) var continuityGaps = 0
    private(set) var continuityOverlaps = 0

    func open(stream: UnsafeMutablePointer<AVStream>) throws {
        guard let codecpar = stream.pointee.codecpar else {
            throw AudioDecoderError.noCodecParameters
        }

        timeBase = stream.pointee.time_base
        sourceStart = stream.pointee.start_time == Int64.min ? nil : stream.pointee.start_time
        if sourceParameters != nil { avcodec_parameters_free(&sourceParameters) }
        sourceParameters = avcodec_parameters_alloc()
        if let sourceParameters { _ = avcodec_parameters_copy(sourceParameters, codecpar) }
        sampleRate = codecpar.pointee.sample_rate
        channels = codecpar.pointee.ch_layout.nb_channels
        if channels <= 0 || channels > 8 { channels = 2 }

        guard let codec = avcodec_find_decoder(codecpar.pointee.codec_id) else {
            throw AudioDecoderError.unsupportedCodec
        }

        guard let ctx = avcodec_alloc_context3(codec) else {
            throw AudioDecoderError.contextAllocationFailed
        }
        codecContext = ctx

        guard avcodec_parameters_to_context(ctx, codecpar) >= 0 else {
            throw AudioDecoderError.parameterCopyFailed
        }

        // The packets' time base, so a decoder that trims priming (Opus pre-skip, a LAME header, an MP4
        // edit list's AAC delay) moves the frame's pts past what it trimmed; without it the pts stays the
        // packet's and the first audio played that much early.
        ctx.pointee.pkt_timebase = stream.pointee.time_base
        guard openAudioDecoder(ctx, codec) >= 0 else {
            throw AudioDecoderError.openFailed
        }

        // Resampler built lazily from the first frame, not here: TrueHD (and codecs advertising
        // AV_CHANNEL_ORDER_UNSPEC or sample_fmt=NONE in codecpar pre-frame) would fail swr_alloc_set_opts2 here,
        // bubbling up as open-failed -> audioAvailable=false -> no sound. The first frame carries resolved layout/rate/format.

        #if DEBUG
        EngineLog.emit("[AudioDecoder] Opened: \(sampleRate)Hz, \(channels)ch, codec=\(String(cString: codec.pointee.name))", category: .swPlayback)
        #endif
    }

    func decode(packet: UnsafeMutablePointer<AVPacket>) -> [CMSampleBuffer] {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let ctx = codecContext else { return [] }
        var results: [CMSampleBuffer] = []

        let sendRet = avcodec_send_packet(ctx, packet)
        guard sendRet >= 0 else {
            runBreakPending = true
            return []
        }

        var frame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
        defer { av_frame_free(&frame) }
        guard let f = frame else { return [] }

        while avcodec_receive_frame(ctx, f) >= 0 {
            // Lazy resampler init off a real frame with resolved layout/format. On failure drops one frame at
            // most and recovers immediately.
            if swrContext == nil {
                if !initResamplerFromFrame(f) { continue }
            } else if configuredInput.differ(from: f) {
                if let sampleBuffer = rebuildResampler(for: f) { results.append(sampleBuffer) }
                if swrContext == nil { continue }
            }
            take(f, into: &results)
        }

        return results
    }

    /// Tear down and rebuild the resampler for a frame whose input parameters changed mid-stream
    /// (#452). Emits the accumulator first (its bytes are in the OLD output format and must be
    /// neither dropped nor mixed with the new format's) and returns that buffer, if any. The grid is
    /// laid at the decoded rate, so it is laid again at the next frame's. On a failed rebuild `swrContext` stays nil and the
    /// caller skips the frame; the next frame retries, mirroring the lazy-init failure mode.
    private func rebuildResampler(for frame: UnsafeMutablePointer<AVFrame>) -> CMSampleBuffer? {
        let flushed = emitPending()
        EngineLog.emit(
            "[AudioDecoder] input format changed mid-stream ("
            + "\(configuredInput.rate)Hz/\(configuredInput.layout.nb_channels)ch/fmt=\(configuredInput.format.rawValue)"
            + " -> \(frame.pointee.sample_rate)Hz/\(frame.pointee.ch_layout.nb_channels)ch/fmt=\(frame.pointee.format)"
            + "); rebuilding resampler",
            category: .swPlayback)
        swr_free(&swrContext)
        // The grid is laid at the decoded rate, which may have changed.
        grid = nil
        nextPosition = nil
        pendingTrimSamples = 0
        _ = initResamplerFromFrame(frame)
        return flushed
    }

    private func initResamplerFromFrame(_ frame: UnsafeMutablePointer<AVFrame>) -> Bool {
        // Refresh rate/channels from the frame (codecpar was a hint, the frame is truth). Runs on the
        // first frame and again after a mid-stream format change tore the context down (#452).
        if frame.pointee.sample_rate > 0 { sampleRate = frame.pointee.sample_rate }
        let frameChannels = frame.pointee.ch_layout.nb_channels
        output = frameChannels > 0 && frameChannels <= 8
            ? withUnsafePointer(to: &frame.pointee.ch_layout) { ResamplerOutput(source: $0) }
            : ResamplerOutput(channels: channels)
        channels = output.channels

        var outLayout = AVChannelLayout()
        // #401: this is the order the stamped layout has to name, so both come from one place.
        output.makeLayout(into: &outLayout)

        // Input layout: frame's if valid, else a synthesised default. Key for TrueHD 7.1 (the frame has it right
        // after decoding even when codecpar didn't).
        var inLayout = AVChannelLayout()
        if frame.pointee.ch_layout.nb_channels > 0 {
            av_channel_layout_copy(&inLayout, &frame.pointee.ch_layout)
        } else {
            av_channel_layout_default(&inLayout, channels)
        }
        // copy() allocates a channel map for custom-order layouts; uninit the stack structs or that map leaks per init.
        defer {
            av_channel_layout_uninit(&inLayout)
            av_channel_layout_uninit(&outLayout)
        }

        let inFmt = AVSampleFormat(rawValue: frame.pointee.format)
        let inRate = frame.pointee.sample_rate > 0 ? frame.pointee.sample_rate : sampleRate

        let ret = swr_alloc_set_opts2(
            &swrContext,
            &outLayout,
            AV_SAMPLE_FMT_FLT,
            sampleRate,
            &inLayout,
            inFmt,
            inRate,
            0,
            nil
        )
        guard ret >= 0, let swr = swrContext else { return false }
        // Same rate in and out and float out, so of the bridge's options only the downmix normalisation
        // does anything here: a source above 8 channels folded into 7.1 cannot clip.
        AudioBridge.applyResamplerQuality(swr, outputFormat: AV_SAMPLE_FMT_FLT)
        guard swr_init(swrContext) >= 0 else {
            swr_free(&swrContext)
            return false
        }

        do {
            try createFormatDescription()
        } catch {
            swr_free(&swrContext)
            return false
        }

        // What this context was built for; every later frame is compared against it (#452).
        configuredInput.adopt(layout: &inLayout, format: inFmt, rate: inRate)

        #if DEBUG
        EngineLog.emit("[AudioDecoder] Resampler ready: \(sampleRate)Hz, \(channels)ch, inFmt=\(inFmt.rawValue)", category: .swPlayback)
        #endif
        return true
    }

    /// Flush the decoder (call at EOF or seek).
    func flush() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let ctx = codecContext else { return }
        avcodec_flush_buffers(ctx)
        // Drop the coalesced samples; after a seek they'd be at the wrong PTS anyway.
        resetPending()
        nextPosition = nil
        runBreakPending = true
        pendingTrimSamples = 0
        #if DEBUG
        _loggedZeroConvert = false
        #endif
    }

    /// Drain at source EOF: send a NULL packet to flush the decoder's internal delay frames into the
    /// accumulator, then force-emit the residual (< minSamplesPerBuffer) tail that the gated decode()
    /// path never emits. Without this the final ~21ms+ of every audio-only title was dropped (flush()
    /// discards pending). Mirrors AudioBridge.flush(). Call once at demuxer EOF, before flush()/close().
    func drain() -> [CMSampleBuffer] {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let ctx = codecContext else { return [] }
        var results: [CMSampleBuffer] = []

        avcodec_send_packet(ctx, nil)
        var frame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
        defer { av_frame_free(&frame) }
        if let f = frame {
            while avcodec_receive_frame(ctx, f) >= 0 {
                if swrContext == nil {
                    if !initResamplerFromFrame(f) { continue }
                } else if configuredInput.differ(from: f) {
                    if let sampleBuffer = rebuildResampler(for: f) { results.append(sampleBuffer) }
                    if swrContext == nil { continue }
                }
                take(f, into: &results)
            }
        }
        // Force-emit whatever is left below the coalescing threshold (emitPending only needs > 0 samples).
        if let sampleBuffer = emitPending() { results.append(sampleBuffer) }
        return results
    }

    func close() {
        stateLock.lock()
        defer { stateLock.unlock() }
        if codecContext != nil {
            avcodec_free_context(&codecContext)
        }
        if swrContext != nil {
            swr_free(&swrContext)
        }
        if sourceParameters != nil {
            avcodec_parameters_free(&sourceParameters)
        }
        // The stored copy may hold an allocated channel map for custom-order layouts (#452).
        configuredInput.release()
        codecContext = nil
        swrContext = nil
        audioFormatDescription = nil
    }

    deinit {
        close()
    }

    // MARK: - Format Description

    private func createFormatDescription() throws {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Float64(sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(channels) * 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(channels) * 4,
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32,
            mReserved: 0
        )

        let layoutTag = output.tag
        var layout = AudioChannelLayout(
            mChannelLayoutTag: layoutTag,
            mChannelBitmap: [],
            mNumberChannelDescriptions: 0,
            mChannelDescriptions: (AudioChannelDescription())
        )
        let layoutSize = MemoryLayout<AudioChannelLayout>.size

        var formatDesc: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: layoutSize,
            layout: &layout,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDesc
        )
        guard status == noErr, let desc = formatDesc else {
            throw AudioDecoderError.formatDescriptionFailed
        }
        audioFormatDescription = desc
    }

    // MARK: - Frame → pending buffer → CMSampleBuffer

    /// One decoded frame: placed on the grid, against where the count says it goes, then appended.
    private func take(_ frame: UnsafeMutablePointer<AVFrame>, into results: inout [CMSampleBuffer]) {
        guard let start = position(of: frame) else {
            framesDroppedUnplaced += 1
            return
        }
        if let next = nextPosition, start != next {
            switch AudioContinuity.decide(expected: next, actual: start, tolerance: 0, sampleRate: sampleRate) {
            case .continue:
                break
            case .gap, .jump:
                // The renderer leaves exactly the gap: this frame starts the next buffer at its own place.
                if let buffer = emitPending() { results.append(buffer) }
                continuityGaps += 1
            case .overlap(let samples):
                pendingTrimSamples += Int(samples)
                continuityOverlaps += 1
            }
        }
        appendFrameToPending(frame, at: start)
        if pendingSampleCount >= Self.minSamplesPerBuffer, let buffer = emitPending() {
            results.append(buffer)
        }
    }

    /// Where `frame` starts, in source frames at its rate: on the stream's grid, placed by its timestamp
    /// and every other one of its run (`SourceGrid`); nil while nothing can say. The frame's end is
    /// what is placed: a decoder that trims a codec's delay off the front of the stream's first frame
    /// leaves that frame's start off the lattice, never its end.
    private func position(of frame: UnsafeMutablePointer<AVFrame>) -> Int64? {
        let rate = frame.pointee.sample_rate
        guard rate > 0, let parameters = sourceParameters else { return nil }
        if grid == nil {
            guard let sourceStart else {
                if !reportedNoSourceStart {
                    reportedNoSourceStart = true
                    EngineLog.emit("[AudioDecoder] ERROR: no stream start, so no frame can be placed", category: .swPlayback)
                }
                return nil
            }
            grid = SourceGrid(
                origin: SourceGrid.origin(start: sourceStart, timeBase: timeBase, sampleRate: rate,
                                          initialPadding: parameters.pointee.initial_padding),
                step: SourceGrid.lattice(codecpar: parameters, sampleRate: rate,
                                         decodedFrameSamples: Int64(frame.pointee.nb_samples)),
                tolerance: AudioContinuity.tolerance(sourceTimeBase: timeBase, sampleRate: rate))
            runFrames = 0
        }
        if runBreakPending {
            runBreakPending = false
            grid?.restart()
            runFrames = 0
        }
        let frames = Int64(frame.pointee.nb_samples)
        runFrames += frames
        let end = frame.pointee.pts == Int64.min
            ? nil : av_rescale_q(frame.pointee.pts, timeBase, AVRational(num: 1, den: rate)) + frames
        guard case .position(let at) = grid!.place(relative: runFrames, estimate: end).0 else { return nil }
        return at - frames
    }

    /// Resample one frame and append float-interleaved bytes to the pending accumulator; the first append
    /// gives the buffer its start (`start`, past any overlap trimmed off).
    private func appendFrameToPending(_ frame: UnsafeMutablePointer<AVFrame>, at start: Int64) {
        guard let swr = swrContext else { return }

        let numSamples = Int(frame.pointee.nb_samples)
        guard numSamples > 0 else { return }

        // Every plane swr will read has to be there. The compare in decode() rebuilds on a DECLARED
        // input change; corrupt live MPEG-TS decodes to nb_samples > 0 with a NULL plane and declares
        // nothing, and swr_convert dereferences it just the same (#452).
        guard configuredInput.framePlanesArePresent(frame) else { return }

        let maxOutputSamples = Int(swr_get_out_samples(swr, frame.pointee.nb_samples))
        guard maxOutputSamples > 0 else { return }

        let bytesPerSample = Int(channels) * 4
        let bufferSize = maxOutputSamples * bytesPerSample
        let tempBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { tempBuffer.deallocate() }

        var outPtr: UnsafeMutablePointer<UInt8>? = tempBuffer
        let convertedSamples = withUnsafeMutablePointer(to: &outPtr) { outBuf in
            let srcData = UnsafePointer<UnsafePointer<UInt8>?>(
                OpaquePointer(frame.pointee.extended_data)
            )
            return swr_convert(
                swr,
                outBuf,
                Int32(maxOutputSamples),
                srcData,
                frame.pointee.nb_samples
            )
        }
        #if DEBUG
        if convertedSamples <= 0 && !_loggedZeroConvert {
            _loggedZeroConvert = true
            EngineLog.emit("[AudioDecoder] swr_convert returned \(convertedSamples), pipeline silent from here", category: .swPlayback)
        }
        #endif
        guard convertedSamples > 0 else { return }
        // An overlap `take` found comes off the start of what this frame converted to.
        let skip = min(pendingTrimSamples, Int(convertedSamples))
        pendingTrimSamples -= skip
        let kept = Int(convertedSamples) - skip
        guard kept > 0 else { return }

        nextPosition = start + Int64(convertedSamples)
        if pendingSampleCount == 0 { pendingStart = start + Int64(skip) }

        pendingBytes.append(tempBuffer + skip * bytesPerSample, count: kept * bytesPerSample)
        pendingSampleCount += kept
    }

    /// Build a CMSampleBuffer from the pending accumulator and reset it. Nil if nothing pending.
    private func emitPending() -> CMSampleBuffer? {
        guard pendingSampleCount > 0,
              let formatDesc = audioFormatDescription,
              !pendingBytes.isEmpty
        else { return nil }

        guard let start = pendingStart else {
            resetPending()
            return nil
        }
        let totalBytes = pendingBytes.count
        let totalSamples = pendingSampleCount

        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: totalBytes,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: totalBytes,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == kCMBlockBufferNoErr, let block = blockBuffer else {
            resetPending()
            return nil
        }

        status = pendingBytes.withUnsafeBytes { bytes -> OSStatus in
            guard let base = bytes.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(
                with: base,
                blockBuffer: block,
                offsetIntoDestination: 0,
                dataLength: totalBytes
            )
        }
        guard status == kCMBlockBufferNoErr else {
            resetPending()
            return nil
        }

        let outPTS = CMTime(value: start, timescale: sampleRate)

        // Single timing entry: CoreMedia treats `duration` as per-SAMPLE, so LPCM must be 1/sampleRate. Stamping
        // the buffer total made GetDuration report totalSamples^2/sampleRate (~22s for 1024 samples), wedging
        // AudioPlaybackHost's buffer-ahead gate after one packet.
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: sampleRate),
            presentationTimeStamp: outPTS,
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDesc,
            sampleCount: CMItemCount(totalSamples),
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        resetPending()
        guard status == noErr, let sample = sampleBuffer else { return nil }
        return sample
    }

    private func resetPending() {
        pendingBytes.removeAll(keepingCapacity: true)
        pendingSampleCount = 0
        pendingStart = nil
    }
}

enum AudioDecoderError: Error, CustomStringConvertible, LocalizedError {
    case noCodecParameters
    case unsupportedCodec
    case contextAllocationFailed
    case parameterCopyFailed
    case openFailed
    case formatDescriptionFailed

    var description: String {
        switch self {
        case .noCodecParameters: "AudioDecoder: audio stream has no codec parameters"
        case .unsupportedCodec: "AudioDecoder: no decoder for the audio codec"
        case .contextAllocationFailed: "AudioDecoder: avcodec_alloc_context3 failed"
        case .parameterCopyFailed: "AudioDecoder: avcodec_parameters_to_context failed"
        case .openFailed: "AudioDecoder: decoder open failed"
        case .formatDescriptionFailed: "AudioDecoder: could not build the output format description"
        }
    }

    var errorDescription: String? { description }
}

/// Opens an audio decoder at the programme's reference dynamics. FFmpeg's AC-3 and E-AC-3 decoders
/// apply the stream's dynamic range compression in full by default (`drc_scale` 1); a receiver
/// decoding the same bitstream plays it uncompressed unless asked, so the engine does too.
///
/// They also fill the coefficients the encoder gave no bits with noise (A/52's dither), from a
/// generator that by default runs on from the decoder's open, so a frame decodes differently with
/// every frame before it and a decode started anywhere never meets a continuous one (measured over 60
/// starts in four files: never once). `cons_noisegen` seeds it from each frame's own bytes: the same
/// noise level and spectrum, A/52 leaves the generator to the decoder, and a frame decodes the same
/// every time. Decoders without these options ignore them.
func openAudioDecoder(_ ctx: UnsafeMutablePointer<AVCodecContext>, _ codec: UnsafePointer<AVCodec>) -> Int32 {
    var options: OpaquePointer?
    av_dict_set(&options, "drc_scale", "0", 0)
    av_dict_set(&options, "cons_noisegen", "1", 0)
    defer { av_dict_free(&options) }
    return avcodec_open2(ctx, codec, &options)
}
