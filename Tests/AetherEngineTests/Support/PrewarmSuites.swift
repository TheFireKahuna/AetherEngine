import Testing

/// Every suite that warms a source (#551, #647). Most warm into a source cache of their own, but two
/// go through `SourceByteCache.shared`, and all of them lean on the process-wide origin budget, so
/// they run one after another rather than interleaving warms and opens across suites.
/// `.serialized` here is recursive: the suites nested in it run one after another.
@Suite(.serialized)
enum PrewarmSuites {}
