import Testing
@testable import AetherEngine

@Suite("AE#550 (the cue prewarm runs only where a seek loads an index, and is not a linear read)")
struct Issue550CuePrewarmPolicyTests {

    @Test("an ordinary seekable Matroska source prewarms, which is what loads the index")
    func seekableSourcePrewarms() {
        #expect(HLSVideoEngine.cuePrewarmMayRun(loadsIndexOnFirstSeek: true, hasSegmentedReader: false,
                                                isSourceSeekable: true))
    }

    @Test("a forward-only source does not: the prefix the seek would read is the producer's only pass")
    func forwardOnlySourceDoesNotPrewarm() {
        #expect(!HLSVideoEngine.cuePrewarmMayRun(loadsIndexOnFirstSeek: true, hasSegmentedReader: false,
                                                 isSourceSeekable: false))
    }

    @Test("a segmented reader keeps its own AE#268 exemption, seekable or not")
    func segmentedReaderNeverPrewarms() {
        #expect(!HLSVideoEngine.cuePrewarmMayRun(loadsIndexOnFirstSeek: true, hasSegmentedReader: true,
                                                 isSourceSeekable: true))
        #expect(!HLSVideoEngine.cuePrewarmMayRun(loadsIndexOnFirstSeek: true, hasSegmentedReader: true,
                                                 isSourceSeekable: false))
    }

    @Test("a container with no index a seek loads does not: on TS the seek was a whole-file search")
    func noLazyIndexNoPrewarm() {
        #expect(!HLSVideoEngine.cuePrewarmMayRun(loadsIndexOnFirstSeek: false, hasSegmentedReader: false,
                                                 isSourceSeekable: true))
    }
}
