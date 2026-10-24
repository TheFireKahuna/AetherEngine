import Foundation
import AetherLibavcodec

/// Whether the software host's decoders can take a packet whose role a program change may have moved.
///
/// The decoders are opened for the stream that carried each role at the start (`roleSources`). A
/// transport stream's PMT can later hand a role to another PID (`ProgramSuccession`), and `Demuxer`
/// passes that PID's packets on under the role's index, saying where each came from
/// (`Demuxer.sourceStream(of:)`). The same codec goes on into the same decoder, which reads the new
/// stream's in-band parameters; another codec cannot, so its packets are held out and the session is
/// rebuilt once at the playhead (`onCodecChange`), where the next host opens decoders for it. Asked
/// where packets are consumed, not where they are read: the read-ahead and the live ring read ahead
/// of the playhead, and a rebuild asked from there would land before the change and ask again.
final class SoftwareSourceWatch: @unchecked Sendable {
    enum Verdict: Equatable {
        case decode
        case drop
    }

    private let lock = NSLock()
    private let videoIndex: Int32
    private let audioIndex: Int32
    private var videoSource: Int32
    private var audioSource: Int32
    private let codec: @Sendable (Int32) -> AVCodecID?
    private let onCodecChange: @Sendable (String) -> Void
    private var asked = false

    init(videoIndex: Int32, videoSource: Int32, audioIndex: Int32, audioSource: Int32,
         codec: @escaping @Sendable (Int32) -> AVCodecID?, onCodecChange: @escaping @Sendable (String) -> Void) {
        self.videoIndex = videoIndex
        self.videoSource = videoSource
        self.audioIndex = audioIndex
        self.audioSource = audioSource
        self.codec = codec
        self.onCodecChange = onCodecChange
    }

    /// What to do with a packet of `streamIndex` read from `source`.
    func verdict(streamIndex: Int32, source: Int32) -> Verdict {
        lock.lock()
        let isVideo = streamIndex == videoIndex
        guard isVideo || (audioIndex >= 0 && streamIndex == audioIndex) else { lock.unlock(); return .decode }
        let current = isVideo ? videoSource : audioSource
        guard source != current else { lock.unlock(); return .decode }
        if codec(source) == codec(current) {
            if isVideo { videoSource = source } else { audioSource = source }
            lock.unlock()
            return .decode
        }
        let first = !asked
        asked = true
        lock.unlock()
        if first {
            onCodecChange("the \(isVideo ? "video" : "audio") moved to stream \(source), another codec than stream \(current)")
        }
        return .drop
    }
}
