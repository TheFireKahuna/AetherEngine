// A legible option picked in AVKit's own subtitle menu maps back to the served rendition, the inverse of
// the match `setNativeSubtitleSelected` makes.
import Testing
@testable import AetherEngine

@Suite("Native subtitle option to rendition")
struct NativeSubtitleOptionMappingTests {

    @Test("the n-th option in a language is the n-th rendition in that language")
    func sameLanguageRank() {
        // AVFoundation normalizes the playlist's LANGUAGE ("ger" reads back "de").
        let tracks: [String?] = ["eng", "ger", "eng", "ger"]
        let options: [String?] = ["en", "de", "en", "de"]
        #expect(AetherEngine.nativeOrdinal(forOptionAt: 0, optionLanguageTags: options, trackLanguages: tracks) == 0)
        #expect(AetherEngine.nativeOrdinal(forOptionAt: 1, optionLanguageTags: options, trackLanguages: tracks) == 1)
        #expect(AetherEngine.nativeOrdinal(forOptionAt: 2, optionLanguageTags: options, trackLanguages: tracks) == 2)
        #expect(AetherEngine.nativeOrdinal(forOptionAt: 3, optionLanguageTags: options, trackLanguages: tracks) == 3)
    }

    @Test("a language-less option is matched by position")
    func untagged() {
        #expect(AetherEngine.nativeOrdinal(forOptionAt: 1, optionLanguageTags: ["en", nil], trackLanguages: ["eng", nil]) == 1)
    }

    @Test("an option no rendition backs maps to nothing")
    func unbacked() {
        #expect(AetherEngine.nativeOrdinal(forOptionAt: 1, optionLanguageTags: ["en", "fr"], trackLanguages: ["eng"]) == nil)
        #expect(AetherEngine.nativeOrdinal(forOptionAt: 5, optionLanguageTags: ["en"], trackLanguages: ["eng"]) == nil)
    }
}
