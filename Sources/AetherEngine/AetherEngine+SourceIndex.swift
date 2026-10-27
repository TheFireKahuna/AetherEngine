import Foundation
import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil

/// What every consumer of a source's container index shares, so they read it the same way: the
/// reader its blocks are fetched through, and the streams its tracks map onto.
extension AetherEngine {

    /// The exact range reader a remote source's index and blocks are read through
    /// (`RangeReadableIOReader`): no read-ahead window, held bytes served from the source cache, one
    /// reader for any number of lanes. It opens against the size the session already learned, so it

}
