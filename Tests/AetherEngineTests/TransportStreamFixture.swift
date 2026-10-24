import Foundation
@testable import AetherEngine

/// Transport streams written here cell by cell around real H.264, for tests that need libavformat
/// itself to demux a TS: its parser flags the IDRs, so keyframes are the real thing.
///
/// `h264` is 50 access units (2 s at 25 fps, GOP 10, two B-frames per P), made with
///
///     ffmpeg -f lavfi -i testsrc=size=32x32:rate=25:duration=2 -pix_fmt yuv420p -c:v libx264 \
///         -profile:v main -bf 2 -g 10 -keyint_min 10 -sc_threshold 0 -preset ultrafast -crf 40 \
///         -x264-params aud=1:repeat-headers=1:b-pyramid=0 -f h264
///
/// and `matroska` is the same stream remuxed (`-c copy`) into Matroska. The composition offsets are
/// the ones ffmpeg's own mpegts muxer gave those frames. `ac3` is 22 AC-3 frames of 256 bytes
/// (`ffmpeg -f lavfi -i sine=frequency=440:sample_rate=48000:duration=0.7 -c:a ac3 -b:a 64k -f ac3`).
enum TransportStreamFixture {

    static let h264 = Data(base64Encoded: """
        AAAAAQkQAAAAAWdNQArpktgIgAAAAwCAAAAZB4kSnAAAAAFozgOcgAAAAQYF//+Z3EXpvebZSLeWLNgg2SPu73gyNjQgLSBjb3JlIDE2NSByMz
        IyMiBiMzU2MDVhIC0gSC4yNjQvTVBFRy00IEFWQyBjb2RlYyAtIENvcHlsZWZ0IDIwMDMtMjAyNSAtIGh0dHA6Ly93d3cudmlkZW9sYW4ub3Jn
        L3gyNjQuaHRtbCAtIG9wdGlvbnM6IGNhYmFjPTAgcmVmPTEgZGVibG9jaz0wOjA6MCBhbmFseXNlPTA6MCBtZT1kaWEgc3VibWU9MCBwc3k9MS
        Bwc3lfcmQ9MS4wMDowLjAwIG1peGVkX3JlZj0wIG1lX3JhbmdlPTE2IGNocm9tYV9tZT0xIHRyZWxsaXM9MCA4eDhkY3Q9MCBjcW09MCBkZWFk
        em9uZT0yMSwxMSBmYXN0X3Bza2lwPTEgY2hyb21hX3FwX29mZnNldD0wIHRocmVhZHM9MSBsb29rYWhlYWRfdGhyZWFkcz0xIHNsaWNlZF90aH
        JlYWRzPTAgbnI9MCBkZWNpbWF0ZT0xIGludGVybGFjZWQ9MCBibHVyYXlfY29tcGF0PTAgY29uc3RyYWluZWRfaW50cmE9MCBiZnJhbWVzPTIg
        Yl9weXJhbWlkPTAgYl9hZGFwdD0wIGJfYmlhcz0wIGRpcmVjdD0xIHdlaWdodGI9MCBvcGVuX2dvcD0wIHdlaWdodHA9MCBrZXlpbnQ9MTAga2
        V5aW50X21pbj02IHNjZW5lY3V0PTAgaW50cmFfcmVmcmVzaD0wIHJjPWNyZiBtYnRyZWU9MCBjcmY9NDAuMCBxY29tcD0wLjYwIHFwbWluPTAg
        cXBtYXg9NjkgcXBzdGVwPTQgaXBfcmF0aW89MS40MCBwYl9yYXRpbz0xLjMwIGFxPTAAgAAAAWWIhAHQYwAPho96hyYaos/qMAEbf8rwv8mB4i
        S/ZDxGAx88eQIZ7n4YgGCQwOOwVsjItzDXB5YeWAA1ZJg6Z/z95XvH1TAiBMFoEwGMANB8u5EGNcUAy/8HRll18Jfz6YAZvYqz/m+C6fWjIM/d
        8MIUATCCoqDuIXZhmhivLByxNM40hBh/oGeXri0CYLQJgLOAKyCgkJ8pJMv9fcANB2Sk3l7/IhJcpAYQrkJSNRY3wsvYDJSwOAASgKEAAXoJHB
        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
        sAAAAAEJUAAAAQGekIGIsA==
        """, options: .ignoreUnknownCharacters)!

    static let matroska = Data(base64Encoded: """
        GkXfo6NChoEBQveBAULygQRC84EIQoKIbWF0cm9za2FCh4EEQoWBAhhTgGcBAAAAAAAOJRFNm3TAv4TTVm5fTbuLU6uEFUmpZlOsgaFNu4tTq4
        QWVK5rU6yB7027jFOrhBJUw2dTrIIBiE27jFOrhBxTu2tTrIINvewBAAAAAAAAUwAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
        AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAFUmpZsm/hCAVjUcq17GDD0JATYCMTGF2ZjYzLjEuMTAyV0
        GMTGF2ZjYzLjEuMTAyc6SQrMF+PXTnD4mHSXZ5GiMVS0SJiECfQAAAAAAAFlSua0CTv4SscdD2rgEAAAAAAACE14EBc8WIM9+7AWVmkz2cgQAi
        tZyDdW5kiIEAho9WX01QRUc0L0lTTy9BVkODgQEj44OEAmJaAOCUsIEguoEgmoECVbCIVbeBAVW4gQJV7oEA7AEAAAAAAAACAABjoqUBTUAK/+
        EAFWdNQArpktgIgAAAAwCAAAAZB4kSnAEABWjOA5yAElTDZ92/hHnSIJtzc59jwIBnyJlFo4dFTkNPREVSRIeMTGF2ZjYzLjEuMTAyc3OyY8CL
        Y8WIM9+7AWVmkz1nyKFFo4hEVVJBVElPTkSHkzAwOjAwOjAyLjAwMDAwMDAwMAAfQ7Z1S82/hPkMnHjngQCjQ+CBAACAAAAAAgkQAAAAFWdNQA
        rpktgIgAAAAwCAAAAZB4kSnAAAAAVozgOcgAAAAp0GBf//mdxF6b3m2Ui3lizYINkj7u94MjY0IC0gY29yZSAxNjUgcjMyMjIgYjM1NjA1YSAt
        IEguMjY0L01QRUctNCBBVkMgY29kZWMgLSBDb3B5bGVmdCAyMDAzLTIwMjUgLSBodHRwOi8vd3d3LnZpZGVvbGFuLm9yZy94MjY0Lmh0bWwgLS
        BvcHRpb25zOiBjYWJhYz0wIHJlZj0xIGRlYmxvY2s9MDowOjAgYW5hbHlzZT0wOjAgbWU9ZGlhIHN1Ym1lPTAgcHN5PTEgcHN5X3JkPTEuMDA6
        MC4wMCBtaXhlZF9yZWY9MCBtZV9yYW5nZT0xNiBjaHJvbWFfbWU9MSB0cmVsbGlzPTAgOHg4ZGN0PTAgY3FtPTAgZGVhZHpvbmU9MjEsMTEgZm
        FzdF9wc2tpcD0xIGNocm9tYV9xcF9vZmZzZXQ9MCB0aHJlYWRzPTEgbG9va2FoZWFkX3RocmVhZHM9MSBzbGljZWRfdGhyZWFkcz0wIG5yPTAg
        ZGVjaW1hdGU9MSBpbnRlcmxhY2VkPTAgYmx1cmF5X2NvbXBhdD0wIGNvbnN0cmFpbmVkX2ludHJhPTAgYmZyYW1lcz0yIGJfcHlyYW1pZD0wIG
        JfYWRhcHQ9MCBiX2JpYXM9MCBkaXJlY3Q9MSB3ZWlnaHRiPTAgb3Blbl9nb3A9MCB3ZWlnaHRwPTAga2V5aW50PTEwIGtleWludF9taW49NiBz
        Y2VuZWN1dD0wIGludHJhX3JlZnJlc2g9MCByYz1jcmYgbWJ0cmVlPTAgY3JmPTQwLjAgcWNvbXA9MC42MCBxcG1pbj0wIHFwbWF4PTY5IHFwc3
        RlcD00IGlwX3JhdGlvPTEuNDAgcGJfcmF0aW89MS4zMCBhcT0wAIAAAAEPZYiEAdBjAA+Gj3qHJhqiz+owARt/yvC/yYHiJL9kPEYDHzx5Ahnu
        fhiAYJDA47BWyMi3MNcHlh5YADVkmDpn/P3le8fVMCIEwWgTAYwA0Hy7kQY1xQDL/wdGWXXwl/PpgBm9irP+b4Lp9aMgz93wwhQBMIKioO4hdm
        GaGK8sHLE0zjSEGH+gZ5euLQJgtAmAs4ArIKCQnykky/19wA0HZKTeXv8iElykBhCuQlI1FjfCy9gMlLA4ABKAoQABegkcFhEoEPQNQ+cBqQju
        UAIu6huf4FnAAueUBu7AiLE09v4Aw3omdV4XRCy6cquW/kFPsB0xywhAGgYWra3MBV3K0JNhk3DlHPYHOvKMCDqfQKOUgQB4AAAAAAIJMAAAAA
        ZBmiYBBFijlIEAKAAAAAACCVAAAAAGAZ5CgKIso5SBAFAAAAAAAglQAAAABgGeRICiLKOYgQDwAAAAAAIJMAAAAApBmkwCk+r/Uw2Ao5SBAKAA
        AAAAAglQAAAABgGeaICSLKOUgQDIAAAAAAIJUAAAAAYBnmqAgiyjn4EBaAAAAAACCTAAAAARQZpyBk+G4vyiQ/tn/gjivuajlIEBGAAAAAACCV
        AAAAAGAZ6Ogciwo5SBAUAAAAAAAglQAAAABgGekIGIsKNA6YEBkIAAAAACCRAAAAAVZ01ACumS2AiAAAADAIAAABkHiRKcAAAABWjOA5yAAAAA
        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
        """, options: .ignoreUnknownCharacters)!

    static let ac3 = Data(base64Encoded: """
        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
        +GrqC6VW+FKJC7XYdkovLiENneDtdg==
        """, options: .ignoreUnknownCharacters)!

    /// `ac3` split into its frames.
    static let audioFrames: [[UInt8]] = {
        let bytes = [UInt8](ac3)
        return stride(from: 0, to: bytes.count, by: 256).map { Array(bytes[$0..<min($0 + 256, bytes.count)]) }
    }()

    struct AccessUnit {
        var bytes: [UInt8]
        /// PTS minus DTS, in 90 kHz ticks.
        var compositionOffset: Int64
        var isKey: Bool
    }

    /// `h264` split at its access unit delimiters, in decode order.
    static let accessUnits: [AccessUnit] = {
        let bytes = [UInt8](h264)
        var starts: [Int] = []
        var i = 0
        while i + 4 < bytes.count {
            if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 0, bytes[i + 3] == 1, bytes[i + 4] & 0x1F == 9 {
                starts.append(i)
            }
            i += 1
        }
        let pattern: [Int64] = [1, 3, 0, 0, 3, 0, 0, 3, 0, 0]
        return starts.indices.map { k in
            let end = k + 1 < starts.count ? starts[k + 1] : bytes.count
            return AccessUnit(bytes: Array(bytes[starts[k]..<end]), compositionOffset: pattern[k % 10] * 3600,
                              isKey: k % 10 == 0)
        }
    }()

    static let frameTicks: Int64 = 3600
    static let pmtPID = 0x100

    /// A run of the stream under one PMT.
    struct Program {
        var frames: Int
        var videoPID = 0x1011
        /// The PMT's stream_type for the video: 0x1B H.264, 0x24 HEVC.
        var videoStreamType: UInt8 = 0x1B
        var pmtVersion: UInt8 = 0
        /// An AC-3 track on this PID, one frame beside each video frame; nil for none.
        var audioPID: Int? = nil
        var audioStreamType: UInt8 = 0x81
        /// The PMT's stream_identifier_descriptor tag for the video, which libavformat matches a
        /// changed PMT's streams by when it merges versions.
        var componentTag: UInt8?
    }

    struct Written {
        var data: Data
        /// Every keyframe's PES: where its first cell is and its decode time.
        var keyframes: [(pos: Int64, dts: Int64)]
        /// Every frame's decode and presentation time, in order.
        var frames: [(dts: Int64, pts: Int64)]
    }

    /// `programs` one after the other, the frames cycling through `accessUnits` from `startingAt`
    /// (a start past 0 is mid-GOP, as a DVR recording starts), each frame enlarged by `padding` bytes
    /// of filler NAL so the stream has a size seeks can be measured on.
    static func write(_ programs: [Program], startingAt start: Int = 0, firstDTS: Int64 = 900_000,
                      padding: Int = 0) -> Written {
        var w = Writer()
        var keyframes: [(pos: Int64, dts: Int64)] = []
        var frames: [(dts: Int64, pts: Int64)] = []
        var frame = 0
        for program in programs {
            for k in 0..<program.frames {
                if k % 25 == 0 {
                    w.section(pid: 0, [0x00, 0xB0, 13, 0x00, 0x01, 0xC1, 0x00, 0x00, 0x00, 0x01,
                                       0xE0 | UInt8(pmtPID >> 8), UInt8(pmtPID & 0xFF)])
                    w.section(pid: pmtPID, pmt(program))
                }
                let unit = accessUnits[(start + frame) % accessUnits.count]
                let dts = firstDTS + Int64(frame) * frameTicks
                let pts = dts + unit.compositionOffset
                var payload = unit.bytes
                if padding > 0 { payload += [0, 0, 0, 1, 0x0C] + [UInt8](repeating: 0xFF, count: padding) + [0x80] }
                if let audioPID = program.audioPID {
                    w.pes(pid: audioPID, Writer.audioPES(pts: dts, payload: audioFrames[frame % audioFrames.count]))
                }
                if unit.isKey { keyframes.append((Int64(w.bytes.count), dts)) }
                frames.append((dts, pts))
                w.pes(pid: program.videoPID, Writer.pes(streamID: 0xE0, pts: pts, dts: dts, payload: payload),
                      firstAdaptation: Writer.pcrAdaptation(dts - 3000, randomAccess: unit.isKey))
                frame += 1
            }
        }
        return Written(data: Data(w.bytes), keyframes: keyframes, frames: frames)
    }

    private static func pmt(_ program: Program) -> [UInt8] {
        let descriptors: [UInt8] = program.componentTag.map { [0x52, 1, $0] } ?? []
        // The HDMV registration is what makes 0x81 AC-3 (Blu-ray's stream types).
        let programInfo: [UInt8] = [0x05, 4] + Array("HDMV".utf8)
        var streams: [UInt8] = [program.videoStreamType, 0xE0 | UInt8(program.videoPID >> 8), UInt8(program.videoPID & 0xFF),
                                0xF0, UInt8(descriptors.count)] + descriptors
        if let audioPID = program.audioPID {
            streams += [program.audioStreamType, 0xE0 | UInt8(audioPID >> 8), UInt8(audioPID & 0xFF), 0xF0, 0x00]
        }
        let body: [UInt8] = [0x00, 0x01, 0xC1 | (program.pmtVersion & 0x1F) << 1, 0x00, 0x00,
                             0xE0 | UInt8(program.videoPID >> 8), UInt8(program.videoPID & 0xFF),
                             0xF0, UInt8(programInfo.count)] + programInfo + streams
        return [0x02, 0xB0 | UInt8(((body.count + 4) >> 8) & 0x0F), UInt8((body.count + 4) & 0xFF)] + body
    }

    /// 188-byte cells, continuity counted per PID, the last cell of a PES stuffed in its adaptation field.
    struct Writer {
        private(set) var bytes: [UInt8] = []
        private var cc: [Int: UInt8] = [:]

        mutating func cell(pid: Int, start: Bool, adaptation: [UInt8]? = nil, payload: ArraySlice<UInt8>) {
            let needsAdaptation = adaptation != nil || payload.count < 184
            let counter = cc[pid] ?? 0
            cc[pid] = (counter + 1) & 0x0F
            var out: [UInt8] = [0x47, (start ? 0x40 : 0) | UInt8((pid >> 8) & 0x1F), UInt8(pid & 0xFF),
                                UInt8(needsAdaptation ? 0x30 : 0x10) | counter]
            if needsAdaptation {
                let length = 183 - payload.count
                out.append(UInt8(length))
                if length > 0 {
                    let body = adaptation ?? [0x00]
                    out += body + [UInt8](repeating: 0xFF, count: length - body.count)
                }
            }
            out += payload
            bytes += out
        }

        /// One PES over as many cells as it takes; `firstAdaptation` rides the first.
        mutating func pes(pid: Int, _ pes: [UInt8], firstAdaptation: [UInt8]? = nil) {
            var at = 0
            var first = true
            while at < pes.count {
                let adaptation = first ? firstAdaptation : nil
                let room = 184 - (adaptation.map { $0.count + 1 } ?? 0)
                let n = min(room, pes.count - at)
                cell(pid: pid, start: first, adaptation: adaptation, payload: pes[at..<at + n])
                at += n
                first = false
            }
        }

        mutating func section(pid: Int, _ section: [UInt8]) {
            var payload: [UInt8] = [0x00] + section + Self.crc32(section)
            payload += [UInt8](repeating: 0xFF, count: 184 - payload.count)
            cell(pid: pid, start: true, payload: payload[...])
        }

        static func crc32(_ bytes: [UInt8]) -> [UInt8] {
            var crc: UInt32 = 0xFFFF_FFFF
            for byte in bytes {
                crc ^= UInt32(byte) << 24
                for _ in 0..<8 { crc = crc & 0x8000_0000 != 0 ? (crc << 1) ^ 0x04C1_1DB7 : crc << 1 }
            }
            return [UInt8(crc >> 24), UInt8((crc >> 16) & 0xFF), UInt8((crc >> 8) & 0xFF), UInt8(crc & 0xFF)]
        }

        static func timestamp(_ prefix: UInt8, _ ts: Int64) -> [UInt8] {
            let v = UInt64(ts) & ((1 << 33) - 1)
            return [(prefix << 4) | UInt8((v >> 29) & 0x0E) | 1, UInt8((v >> 22) & 0xFF),
                    UInt8((v >> 14) & 0xFE) | 1, UInt8((v >> 7) & 0xFF), UInt8((v << 1) & 0xFE) | 1]
        }

        /// A video PES: unbounded, PTS and DTS.
        static func pes(streamID: UInt8, pts: Int64, dts: Int64, payload: [UInt8]) -> [UInt8] {
            let header: [UInt8] = [0x84, 0xC0, 10] + timestamp(3, pts) + timestamp(1, dts)
            return [0, 0, 1, streamID, 0, 0] + header + payload
        }

        /// An audio PES in one cell: bounded, PTS only.
        static func audioPES(pts: Int64, payload: [UInt8]) -> [UInt8] {
            let header: [UInt8] = [0x84, 0x80, 5] + timestamp(2, pts)
            let length = header.count + payload.count
            return [0, 0, 1, 0xBD, UInt8(length >> 8), UInt8(length & 0xFF)] + header + payload
        }

        static func pcrAdaptation(_ base: Int64, randomAccess: Bool) -> [UInt8] {
            let b = UInt64(base) & ((1 << 33) - 1)
            return [(randomAccess ? 0x40 : 0) | 0x10, UInt8((b >> 25) & 0xFF), UInt8((b >> 17) & 0xFF),
                    UInt8((b >> 9) & 0xFF), UInt8((b >> 1) & 0xFF), UInt8((b & 1) << 7) | 0x7E, 0x00]
        }
    }
}

/// A reader over bytes in memory that counts what is read from it.
final class CountingDataReader: IOReader, @unchecked Sendable {
    private let base: DataIOReader
    private let lock = NSLock()
    private var read = 0

    init(_ data: Data) { base = DataIOReader(data: data) }

    var bytesRead: Int { lock.lock(); defer { lock.unlock() }; return read }

    func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 {
        let got = base.read(buffer, size: size)
        if got > 0 { lock.lock(); read += Int(got); lock.unlock() }
        return got
    }
    func seek(offset: Int64, whence: Int32) -> Int64 { base.seek(offset: offset, whence: whence) }
    func close() { base.close() }
    func cancel() {}
    func makeIndependentReader() -> IOReader? { base.makeIndependentReader() }
    var discImageProbeEnabled: Bool { false }
}
