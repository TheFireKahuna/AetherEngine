import Foundation
import Testing
import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil
@testable import AetherEngine

/// A transport stream whose PMT changes mid-stream, read through `Demuxer`: the stream that takes a
/// role is read under the index the reader chose, its first packet says so, and nothing else moves.
@Suite("Program succession across a PMT change")
struct ProgramSuccessionTests {

    struct Read {
        var stream: Int32
        var dts: Int64
        var change: ProgramSuccession.Change?
    }

    private static func open(_ data: Data) throws -> Demuxer {
        let demuxer = Demuxer()
        try demuxer.open(reader: DataIOReader(data: data))
        return demuxer
    }

    private static func readAll(_ demuxer: Demuxer) throws -> [Read] {
        var out: [Read] = []
        while let packet = try demuxer.readPacket() {
            out.append(Read(stream: packet.pointee.stream_index, dts: packet.pointee.dts,
                            change: demuxer.programChange(on: packet)))
            var p: UnsafeMutablePointer<AVPacket>? = packet
            trackedPacketFree(&p)
        }
        return out
    }

    @Test("a new video PID takes the video's role: every frame on the chosen stream, the first new one marked")
    func videoPIDChange() throws {
        let written = TransportStreamFixture.write([
            .init(frames: 60, audioPID: 0x1100),
            .init(frames: 60, videoPID: 0x1021, pmtVersion: 1, audioPID: 0x1100),
        ])
        let demuxer = try Self.open(written.data)
        defer { demuxer.close() }
        let video = demuxer.videoStreamIndex
        let audio = demuxer.audioStreamIndex
        let reads = try Self.readAll(demuxer)
        // Every frame, in order, on the chosen stream; less the old PID's last frames, which libavformat's
        // parser holds until the end of the stream (it lets a frame go at the next one on its PID) and
        // which then arrive after the new PID's: leftovers, dropped.
        let videoDTS = reads.filter { $0.stream == video }.map(\.dts)
        #expect(videoDTS == videoDTS.sorted())
        #expect(Array(videoDTS.suffix(60)) == written.frames[60...].map(\.dts))
        #expect(videoDTS.count >= 117)
        let changes = reads.compactMap(\.change)
        #expect(changes.count == 1)
        let change = try #require(changes.first)
        #expect(change.logical == video && change.from == video && !change.codecChanged)
        #expect(reads.first(where: { $0.change != nil })?.dts == written.frames[60].dts)
        #expect(reads.filter { $0.stream == audio }.count >= 100)
        // The successor is nobody's new track.
        #expect(demuxer.videoStreamIndex == video)
        #expect(demuxer.audioTrackInfos().count == 1)
    }

    @Test("a codec change at the switch is called out")
    func codecChange() throws {
        let written = TransportStreamFixture.write([
            .init(frames: 60), .init(frames: 60, videoPID: 0x1021, videoStreamType: 0x24, pmtVersion: 1),
        ])
        let demuxer = try Self.open(written.data)
        defer { demuxer.close() }
        let changes = try Self.readAll(demuxer).compactMap(\.change)
        #expect(changes.map(\.codecChanged) == [true])
        #expect(changes.first?.logical == demuxer.videoStreamIndex)
    }

    @Test("a new audio PID takes the audio's role while the video goes on on its own")
    func audioPIDChange() throws {
        let written = TransportStreamFixture.write([
            .init(frames: 60, audioPID: 0x1100),
            .init(frames: 60, pmtVersion: 1, audioPID: 0x1101),
        ])
        let demuxer = try Self.open(written.data)
        defer { demuxer.close() }
        let audio = demuxer.audioStreamIndex
        let reads = try Self.readAll(demuxer)
        let changes = reads.compactMap(\.change)
        #expect(changes.map(\.logical) == [audio])
        #expect(reads.filter { $0.stream == audio }.count >= 100)
        #expect(Set(reads.map(\.stream)) == [demuxer.videoStreamIndex, audio])
    }

    @Test("a track the PMT adds beside the others takes no role and is a track of its own")
    func addedTrackIsNotASuccessor() throws {
        let written = TransportStreamFixture.write([
            .init(frames: 60), .init(frames: 60, pmtVersion: 1, audioPID: 0x1100),
        ])
        let demuxer = try Self.open(written.data)
        defer { demuxer.close() }
        let reads = try Self.readAll(demuxer)
        #expect(reads.allSatisfy { $0.change == nil })
        #expect(demuxer.audioTrackInfos().count == 1)
    }

    @Test("a seek across the change announces it again on the side it lands on")
    func seekAcrossTheChange() throws {
        let written = TransportStreamFixture.write([
            .init(frames: 60), .init(frames: 60, videoPID: 0x1021, pmtVersion: 1),
        ])
        let demuxer = try Self.open(written.data)
        defer { demuxer.close() }
        _ = try Self.readAll(demuxer)
        // Back to the start: the open's own stream, nothing to announce, then the change again.
        #expect(demuxer.seek(to: 0))
        let again = try Self.readAll(demuxer).compactMap(\.change)
        #expect(again.count == 1)
        // Past the change: its first packet is the successor's, which is announced.
        #expect(demuxer.seek(to: Double(written.frames[90].dts) / 90_000))
        let past = try Self.readAll(demuxer)
        #expect(past.first(where: { $0.stream == demuxer.videoStreamIndex })?.change != nil)
    }

    @Test("the programme's PIDs coming back after an ad are a change back to the stream chosen at open")
    func programmeReturns() throws {
        let written = TransportStreamFixture.write([
            .init(frames: 60), .init(frames: 60, videoPID: 0x1021, pmtVersion: 1), .init(frames: 60, pmtVersion: 2),
        ])
        let demuxer = try Self.open(written.data)
        defer { demuxer.close() }
        let video = demuxer.videoStreamIndex
        let reads = try Self.readAll(demuxer)
        let changes = reads.compactMap(\.change)
        #expect(changes.count == 2)
        #expect(changes.first?.from == video && changes.last?.to == video)
        #expect(changes.first?.to == changes.last?.from)
        let videoDTS = reads.filter { $0.stream == video }.map(\.dts)
        #expect(videoDTS == videoDTS.sorted())
        #expect(Array(videoDTS.suffix(60)) == written.frames[120...].map(\.dts))
    }

    @Test("a cold seek past the change finds the new PID's role once its PMT is read")
    func coldSeekPastTheChange() throws {
        let written = TransportStreamFixture.write([
            .init(frames: 60), .init(frames: 60, videoPID: 0x1021, pmtVersion: 1),
        ])
        let demuxer = try Self.open(written.data)
        defer { demuxer.close() }
        let video = demuxer.videoStreamIndex
        #expect(demuxer.seek(to: Double(written.frames[90].dts) / 90_000))
        let reads = try Self.readAll(demuxer)
        let first = try #require(reads.first(where: { $0.stream == video }))
        #expect(first.change?.logical == video)
        #expect(reads.filter { $0.stream == video }.map(\.dts).last == written.frames.last?.dts)
    }

    @Test("roles go by type and order: the second audio's new PID takes the second audio's role, not the first's")
    func rolesByTypeAndOrder() {
        let types: [Int32: Int32] = [0: AVMEDIA_TYPE_VIDEO.rawValue, 1: AVMEDIA_TYPE_AUDIO.rawValue,
                                     2: AVMEDIA_TYPE_AUDIO.rawValue, 3: AVMEDIA_TYPE_AUDIO.rawValue,
                                     4: AVMEDIA_TYPE_AUDIO.rawValue]
        var succession = ProgramSuccession(programs: [.init(id: 1, streams: [0, 1, 2])], streamCount: 3,
                                           mediaType: { types[$0] })
        // The second audio (2) left; 3 takes its place, the first audio (1) stays.
        let now = [ProgramSuccession.Program(id: 1, streams: [0, 1, 3])]
        #expect(succession.adopt(3, programs: now, mediaType: { types[$0] }) == 2)
        #expect(succession.logical(for: 3) == 2)
        // A track added beside the others (4, a third audio) has no role to take.
        let added = [ProgramSuccession.Program(id: 1, streams: [0, 1, 3, 4])]
        #expect(succession.adopt(4, programs: added, mediaType: { types[$0] }) == nil)
        // A stream of the open's never succeeds another role.
        #expect(succession.adopt(1, programs: [.init(id: 1, streams: [0, 3, 1])], mediaType: { types[$0] }) == nil)
    }

    @Test("a successor is discarded as its role is: an audio-only reader gets no video from it")
    func successorInheritsTheDiscard() throws {
        let written = TransportStreamFixture.write([
            .init(frames: 60, audioPID: 0x1100),
            .init(frames: 60, videoPID: 0x1021, pmtVersion: 1, audioPID: 0x1100),
        ])
        let demuxer = try Self.open(written.data)
        defer { demuxer.close() }
        let audio = demuxer.audioStreamIndex
        demuxer.discardAllStreamsExcept([audio])
        let reads = try Self.readAll(demuxer)
        #expect(Set(reads.map(\.stream)) == [audio])
    }
}
