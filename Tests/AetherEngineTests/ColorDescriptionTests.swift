import Foundation
import Testing
import AetherLibavutil
@testable import AetherEngine

struct ColorDescriptionTests {

    private let pq = ColorDescription(
        primaries: AVCOL_PRI_BT2020, transfer: AVCOL_TRC_SMPTE2084,
        matrix: AVCOL_SPC_BT2020_NCL, range: AVCOL_RANGE_MPEG)

    @Test("AE#499: a bitstream that describes itself is never overruled by the container")
    func bitstreamWins() {
        let container = ColorDescription(
            primaries: AVCOL_PRI_BT709, transfer: AVCOL_TRC_BT709,
            matrix: AVCOL_SPC_BT709, range: AVCOL_RANGE_JPEG)
        #expect(ColorDescription.resolved(bitstream: pq, container: container) == pq)
    }

    @Test("AE#499: an empty VUI takes the container's description rather than staying unspecified")
    func containerFillsAnEmptyVUI() {
        #expect(ColorDescription.resolved(bitstream: .unspecified, container: pq) == pq)
    }

    @Test("AE#499: the fields resolve one by one, which is the case that reached the tone mapper")
    func fieldsResolveIndependently() {
        // The reported frame carried a matrix and a range and no transfer: enough for the extractor's
        // HDR gate to read PQ off the stream, not enough for zscale to find a path to linear.
        let partial = ColorDescription(
            primaries: AVCOL_PRI_UNSPECIFIED, transfer: AVCOL_TRC_UNSPECIFIED,
            matrix: AVCOL_SPC_BT2020_NCL, range: AVCOL_RANGE_MPEG)
        #expect(ColorDescription.resolved(bitstream: partial, container: pq) == pq)

        let containerSaysHLG = ColorDescription(
            primaries: AVCOL_PRI_BT2020, transfer: AVCOL_TRC_ARIB_STD_B67,
            matrix: AVCOL_SPC_BT2020_NCL, range: AVCOL_RANGE_MPEG)
        let bitstreamSaysPQ = ColorDescription(
            primaries: AVCOL_PRI_UNSPECIFIED, transfer: AVCOL_TRC_SMPTE2084,
            matrix: AVCOL_SPC_UNSPECIFIED, range: AVCOL_RANGE_UNSPECIFIED)
        let mixed = ColorDescription.resolved(bitstream: bitstreamSaysPQ, container: containerSaysHLG)
        #expect(mixed.transfer == AVCOL_TRC_SMPTE2084)
        #expect(mixed.primaries == AVCOL_PRI_BT2020)
        #expect(mixed.matrix == AVCOL_SPC_BT2020_NCL)
        #expect(mixed.range == AVCOL_RANGE_MPEG)
    }

    @Test("AE#499: two silences stay silent, so nothing is invented for an untagged stream")
    func nothingIsInvented() {
        #expect(ColorDescription.resolved(bitstream: .unspecified, container: .unspecified) == .unspecified)
    }

    private func frame(_ d: ColorDescription) throws -> UnsafeMutablePointer<AVFrame> {
        let f = try #require(av_frame_alloc())
        f.pointee.color_primaries = d.primaries
        f.pointee.color_trc = d.transfer
        f.pointee.colorspace = d.matrix
        f.pointee.color_range = d.range
        return f
    }

    @Test("AE#499: backfilling writes the resolved description onto the frame, once")
    func backfillWritesTheFrame() throws {
        var fill = ColourBackfill(container: pq)
        var frame: UnsafeMutablePointer<AVFrame>? = try self.frame(ColorDescription(
            primaries: AVCOL_PRI_UNSPECIFIED, transfer: AVCOL_TRC_UNSPECIFIED, matrix: AVCOL_SPC_BT2020_NCL, range: AVCOL_RANGE_MPEG))
        defer { av_frame_free(&frame) }
        #expect(fill.fill(frame!) == true)
        #expect(ColorDescription(frame: frame!) == pq)
        // Idempotent: the second pass has nothing left to fill and says so.
        #expect(fill.fill(frame!) == false)
    }

    @Test("AE#499: a container with nothing to say leaves the frame alone")
    func silentContainerChangesNothing() throws {
        var fill = ColourBackfill(container: .unspecified)
        var frame: UnsafeMutablePointer<AVFrame>? = try self.frame(.unspecified)
        defer { av_frame_free(&frame) }
        #expect(fill.fill(frame!) == false)
        #expect(ColorDescription(frame: frame!) == .unspecified)
    }

    @Test("A remux whose bitstream never states its colour is filled from the container throughout")
    func silentBitstreamFilledThroughout() throws {
        var fill = ColourBackfill(container: pq)
        for _ in 0..<3 {
            var frame: UnsafeMutablePointer<AVFrame>? = try self.frame(.unspecified)
            defer { av_frame_free(&frame) }
            fill.fill(frame!)
            #expect(ColorDescription(frame: frame!) == pq)
        }
    }

    @Test("Once the bitstream has stated a field, a later silence is unspecified, not the container's value")
    func statedThenSilentStaysUnspecified() throws {
        // MPEG-TS: the "container" value is the first SPS's own (BT.709 HD); a later SPS without a description.
        let first = ColorDescription(primaries: AVCOL_PRI_BT709, transfer: AVCOL_TRC_BT709, matrix: AVCOL_SPC_BT709,
                                     range: AVCOL_RANGE_MPEG)
        var fill = ColourBackfill(container: first)
        var stated: UnsafeMutablePointer<AVFrame>? = try self.frame(first)
        defer { av_frame_free(&stated) }
        #expect(fill.fill(stated!) == false)
        var silent: UnsafeMutablePointer<AVFrame>? = try self.frame(ColorDescription(
            primaries: AVCOL_PRI_UNSPECIFIED, transfer: AVCOL_TRC_UNSPECIFIED, matrix: AVCOL_SPC_UNSPECIFIED, range: AVCOL_RANGE_MPEG))
        defer { av_frame_free(&silent) }
        #expect(fill.fill(silent!) == false)
        #expect(ColorDescription(frame: silent!).matrix == AVCOL_SPC_UNSPECIFIED)
        // A field the bitstream never stated is still the container's.
        var noRange = ColourBackfill(container: first)
        var partial: UnsafeMutablePointer<AVFrame>? = try self.frame(ColorDescription(
            primaries: AVCOL_PRI_BT709, transfer: AVCOL_TRC_BT709, matrix: AVCOL_SPC_BT709, range: AVCOL_RANGE_UNSPECIFIED))
        defer { av_frame_free(&partial) }
        #expect(noRange.fill(partial!) == true)
        #expect(ColorDescription(frame: partial!).range == AVCOL_RANGE_MPEG)
    }
}
