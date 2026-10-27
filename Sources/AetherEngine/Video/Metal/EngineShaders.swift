import Foundation
import Metal
import os
#if DualLayerDolbyVision
import AetherFELShaders
#endif

/// The engine's own kernels, compiled when the package builds (`Shaders/`; the FEL composer's in `AetherFELShaders`),
/// and the Metal 4 binary archive of their pipelines for the Apple TV 4K's A15 (`Scripts/build-shader-archive.sh`).
enum EngineShaders {

    /// The finisher's, film grain's and the layer's kernels.
    static func library(for device: MTLDevice) throws -> MTLLibrary {
        try library(for: device, bundle: .module)
    }

    #if DualLayerDolbyVision
    /// The FEL composer's kernels.
    static func felLibrary(for device: MTLDevice) throws -> MTLLibrary {
        try library(for: device, bundle: FELShaders.bundle)
    }
    #endif

    /// Every pipeline of the planned set (``PlanarFrameFinisher/archivedRequests(library:felLibrary:)``) translated for the
    /// A15 on the tvOS release the script names: Metal refuses it on any other release or GPU, and the pipelines are then
    /// compiled. Only the tvOS device build looks for it.
    static let archive: URL? = {
        #if os(tvOS) && !targetEnvironment(simulator)
        Bundle.module.url(forResource: archiveName, withExtension: "metallib.lzfse")
        #else
        nil
        #endif
    }()

    static let archiveName = "AetherEngine-pipelines"

    private struct Key: Hashable {
        let device: ObjectIdentifier
        let bundle: String
    }

    private static let libraries = OSAllocatedUnfairLock<[Key: MTLLibrary]>(initialState: [:])

    /// Loaded once per device: the first one loaded is every caller's.
    private static func library(for device: MTLDevice, bundle: Bundle) throws -> MTLLibrary {
        let key = Key(device: ObjectIdentifier(device), bundle: bundle.bundlePath)
        if let known = libraries.withLock({ $0[key] }) { return known }
        let made = try device.makeDefaultLibrary(bundle: bundle)
        return libraries.withLock { known in
            if let first = known[key] { return first }
            known[key] = made
            return made
        }
    }
}

/// A pipeline the engine's archive records: `function` of `library`, with its constants (nil for a function that reads
/// none), as ``GPUPipelines`` asks for it.
@_spi(ShaderArchive) public struct EngineShaderArchiveRequest {
    public let library: MTLLibrary
    public let function: String
    public let constants: MTLFunctionConstantValues?
}

@_spi(ShaderArchive) public enum EngineShaderArchive {
    public static func requests(library: MTLLibrary, felLibrary: MTLLibrary?) -> [EngineShaderArchiveRequest] {
        #if DualLayerDolbyVision
        if let felLibrary {
            requests += DoviFelComposer.SharedPipelines.archivedRequests().map {
                EngineShaderArchiveRequest(library: felLibrary, function: $0.function, constants: $0.constants)
            }
        }
        #endif
        return requests
    }
}
