import Foundation

/// The package's Metal sources, read from the checkout the tests are built from: the app ships them compiled, so their
/// text is only here.
enum ShaderFiles {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    static func text(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    static func finisher() throws -> String { try text("Sources/AetherEngine/Shaders/Finisher.metal") }
    static func filmGrain() throws -> String { try text("Sources/AetherEngine/Shaders/FilmGrain.h") }
    static func dolbyVisionFEL() throws -> String { try text("Sources/AetherFELShaders/Shaders/DolbyVisionFEL.metal") }
}
