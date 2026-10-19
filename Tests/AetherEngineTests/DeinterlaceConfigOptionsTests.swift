import Testing
@testable import AetherEngine

struct DeinterlaceConfigOptionsTests {
    @Test("LoadOptions defaults to auto hardware, field rate")
    func defaults() {
        let o = LoadOptions()
        #expect(o.deinterlaceMode == .auto)
        #expect(o.deinterlaceFieldRate == .field)
        #expect(o.teletextPage == nil)  // Phase-1 field still present
    }

    @Test("the hardware engine prefers bwdif_videotoolbox when linked, else yadif_videotoolbox")
    func hardwareFilterPreference() {
        #expect(DeinterlaceFilter.hardwareFilterName(available: { _ in true }) == "bwdif_videotoolbox")
        #expect(DeinterlaceFilter.hardwareFilterName(available: { $0 == "yadif_videotoolbox" }) == "yadif_videotoolbox")
        #expect(DeinterlaceFilter.hardwareFilterName(available: { _ in false }) == nil)
        // FFmpeg 8.1 (the linked build) ships the yadif kernel only.
        #expect(DeinterlaceFilter.hardwareFilterName() == "yadif_videotoolbox")
    }

    @Test("deinterlace options are settable and Equatable")
    func settable() {
        let a = LoadOptions(deinterlaceMode: .software, deinterlaceFieldRate: .frame)
        #expect(a.deinterlaceMode == .software)
        #expect(a.deinterlaceFieldRate == .frame)
        #expect(a != LoadOptions())
    }
}
