import Testing
import AetherLibavutil
import AetherLibavfilter
@testable import AetherEngine

/// Regression: anamorphic DVD rips rendered "flattened" because SAR (pixel_aspect on the buffer
/// source) was not carried through the deinterlacer to sample_aspect_ratio on the output frame.
struct DeinterlaceSARTests {

    @Test("Deinterlacer preserves the source SAR on its output frames",
          .enabled(if: DeinterlaceTestInput.available, DeinterlaceTestInput.needsHardware))
    func deinterlacePreservesSAR() {
        // NTSC 4:3 DVD SAR: 720x480 displayed at 4:3 is 8:9 pixels.
        let sourceSAR = AVRational(num: 8, den: 9)
        let filter = DeinterlaceFilter()
        defer { filter.teardown() }

        var sawOutput = false
        let run = DeinterlaceTestInput.run(filter, count: 8, sar: sourceSAR, onFrame: { out in
            sawOutput = true
            let outSAR = out.pointee.sample_aspect_ratio
            #expect(outSAR.num == sourceSAR.num && outSAR.den == sourceSAR.den,
                    "deinterlaced SAR \(outSAR.num):\(outSAR.den) lost the source \(sourceSAR.num):\(sourceSAR.den)")
        })
        #expect(run.built)
        #expect(sawOutput, "filter produced no frames")
    }
}
