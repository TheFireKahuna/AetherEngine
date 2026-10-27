import Testing
import Foundation
import AetherLibavformat
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

/// Diagnostic against a real remote MKV: `AE_MKV_INDEX_URL` (with `AE_MKV_INDEX_AUTH`, an Authorization
/// header value) names the file. Reads its subtitle index and a few text frames, and decodes a text
/// track from it, timing each step. Runs only when the variable is set.
