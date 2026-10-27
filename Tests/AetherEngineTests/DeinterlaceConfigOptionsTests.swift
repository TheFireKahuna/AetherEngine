import Testing
@testable import AetherEngine

struct DeinterlaceConfigOptionsTests {
    @Test("LoadOptions defaults to field rate")
    func defaults() {
        let o = LoadOptions()
        #expect(o.deinterlaceFieldRate == .field)
        #expect(o.teletextPage == nil)  // Phase-1 field still present
    }

    @Test("deinterlace options are settable and Equatable")
    func settable() {
        let a = LoadOptions(deinterlaceFieldRate: .frame)
        #expect(a.deinterlaceFieldRate == .frame)
        #expect(a != LoadOptions())
    }
}
