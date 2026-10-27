// A URL source that turned out forward-only used to be forced onto the software host, which cannot
// seek on it either and whose picture never reaches an AirPlay receiver (only its audio follows the
// route). When the container states a duration, the engine now serves it as the sequential origin it
// is. A picture the engine decodes itself still cannot reach a receiver, and `airPlayPictureStaysLocal`
// says so instead of letting the TV play sound only in silence.
import Testing
@testable import AetherEngine

@Suite("Forward-only URL sources are served as sequential origins")
struct ForwardOnlySequentialPromotionTests {

    private func promotes(seekable: Bool = false, live: Bool = false, declared: Bool = false,
                          custom: Bool = false, software: Bool = false,
                          preferred: DecodePath = .automatic, duration: Double = 183.1) -> Bool {
        VideoRoutingPolicy.promotesForwardOnlySourceToSequential(
            isSourceSeekable: seekable, isLive: live, declaredSequential: declared,
            isCustomSource: custom, routedSoftware: software, preferred: preferred,
            containerDurationSeconds: duration)
    }

    @Test("a forward-only VOD URL with a container duration is promoted")
    func promoted() {
        #expect(promotes())
    }

    @Test("everything the promotion must leave alone")
    func leftAlone() {
        #expect(!promotes(seekable: true), "a seekable source keeps the ordinary native path")
        #expect(!promotes(live: true), "live is exempt from the forward-only rule already")
        #expect(!promotes(declared: true), "a host declaration needs no promotion")
        #expect(!promotes(custom: true), "a custom reader is the host's to describe")
        #expect(!promotes(software: true), "the promotion never moves a session between hosts")
        #expect(!promotes(preferred: .software), "a host that asked for software gets software")
    }

    @Test("no usable duration keeps the software path")
    func needsDuration() {
        for duration in [0, -1, .nan, .infinity] as [Double] {
            #expect(!promotes(duration: duration), "promoted with duration \(duration)")
        }
    }

    @Test("only a picture drawn locally is left behind on a wireless receiver")
    func pictureStaysLocal() {
        #expect(AetherEngine.airPlayPictureStaysLocal(pictureDrawnLocally: true, wirelessAirPlayRoute: true))
        #expect(!AetherEngine.airPlayPictureStaysLocal(pictureDrawnLocally: false, wirelessAirPlayRoute: true))
        #expect(!AetherEngine.airPlayPictureStaysLocal(pictureDrawnLocally: true, wirelessAirPlayRoute: false))
    }
}
