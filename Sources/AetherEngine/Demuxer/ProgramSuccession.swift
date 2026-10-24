import Foundation
import AetherLibavformat
import AetherLibavutil

/// Which stream carries each role of a transport stream's programs once their PMT changes.
///
/// An MPEG-TS program can change its stream table mid-stream: an ad on its own PIDs, a recording that
/// crosses a programme boundary, an encoder restart. libavformat gives each new PID a new `AVStream` and
/// rebuilds the program's stream list from the new PMT (`clear_avprogram`), so a reader that chose
/// stream 0 for video at open reads nothing past the change while the video goes on in stream 3.
/// (`merge_pmt_versions` reuses the old stream instead, but drops a codec change on the floor: it updates
/// the stream type before the check that would update the codec.)
///
/// A role is a program, a media type and an ordinal among that program's streams of the type, in PMT
/// order: the second audio of program 1. The stream that holds a role at open is the role's logical
/// stream, the index every reader chose. A new stream succeeds a role only when it takes the role's
/// place in the program and the role's current stream has left it, so a track the PMT adds alongside
/// is never folded into an existing one. A new stream is judged on its first packet, against the
/// program as it stands then: libavformat keeps the program's stream list exact while it reads
/// forward, but `find_stream_info`'s duration estimate (a read of the end, then back) can leave it
/// naming both the old and the new streams until the reading starts over.
struct ProgramSuccession: Sendable {

    struct Program: Sendable, Equatable {
        var id: Int32
        /// The program's streams in PMT order.
        var streams: [Int32]
    }

    /// A role's stream changed under its logical index: handed to a reader on the first packet the
    /// new stream delivers (`Demuxer.programChange(on:)`).
    struct Change: Sendable, Equatable {
        var logical: Int32
        var from: Int32
        var to: Int32
        /// The codec differs: the stream that now carries the role cannot be read with what the
        /// role's previous stream was opened with.
        var codecChanged: Bool
    }

    private struct Role: Hashable, Sendable {
        var program: Int32
        var mediaType: Int32
        var ordinal: Int
    }

    private var logicalByRole: [Role: Int32] = [:]
    /// Streams the open made; a higher index is one a PMT change (or the probe past one) added.
    private let streamCount: Int32
    /// Per logical stream, the stream that carries its role now.
    private var currentByLogical: [Int32: Int32] = [:]
    /// Every successor stream, to the logical stream whose role it took.
    private(set) var logicalBySuccessor: [Int32: Int32] = [:]

    /// The composition at open: `programs` over the open's `streamCount` streams, typed by `mediaType`.
    init(programs: [Program], streamCount: Int32, mediaType: (Int32) -> Int32?) {
        self.streamCount = streamCount
        for program in programs {
            for (role, stream) in Self.roles(of: program, mediaType: mediaType) where logicalByRole[role] == nil {
                logicalByRole[role] = stream
                currentByLogical[stream] = stream
            }
        }
    }

    /// The logical stream `physical` is read as: its role's, or itself.
    func logical(for physical: Int32) -> Int32 { logicalBySuccessor[physical] ?? physical }

    var successors: Set<Int32> { Set(logicalBySuccessor.keys) }

    /// Judges `stream`, read for the first time and not one of the open's: the role's successor when it
    /// holds a role in `programs` (the composition as the read stands, which libavformat keeps exact
    /// while it reads forward) whose current stream has left them. Returns the logical stream it now
    /// stands for, or nil when it takes no role.
    mutating func adopt(_ stream: Int32, programs: [Program], mediaType: (Int32) -> Int32?) -> Int32? {
        guard isNew(stream), logicalBySuccessor[stream] == nil else { return logicalBySuccessor[stream] }
        for program in programs {
            let present = Set(program.streams)
            for (role, candidate) in Self.roles(of: program, mediaType: mediaType) where candidate == stream {
                guard let logical = logicalByRole[role], let current = currentByLogical[logical],
                      !present.contains(current) else { continue }
                logicalBySuccessor[stream] = logical
                currentByLogical[logical] = stream
                return logical
            }
        }
        return nil
    }

    /// Whether `stream` came after the open: a PMT change's, judged on its first packet.
    func isNew(_ stream: Int32) -> Bool { stream >= streamCount }

    /// Video, audio and subtitle streams by role. Other media types are nobody's role.
    private static func roles(of program: Program, mediaType: (Int32) -> Int32?) -> [(Role, Int32)] {
        var ordinals: [Int32: Int] = [:]
        var out: [(Role, Int32)] = []
        for stream in program.streams {
            guard let type = mediaType(stream),
                  type == AVMEDIA_TYPE_VIDEO.rawValue || type == AVMEDIA_TYPE_AUDIO.rawValue
                    || type == AVMEDIA_TYPE_SUBTITLE.rawValue else { continue }
            let ordinal = ordinals[type, default: 0]
            ordinals[type] = ordinal + 1
            out.append((Role(program: program.id, mediaType: type, ordinal: ordinal), stream))
        }
        return out
    }
}
