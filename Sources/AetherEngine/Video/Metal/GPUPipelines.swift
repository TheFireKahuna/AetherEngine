import Foundation
import Metal
import QuartzCore
import os

/// Every compute pipeline the engine and the libraries it encodes for use, made one way per device for the whole
/// process: on Metal 4 by one compiler, taken from the request's binary archive (built ahead of time for this GPU and OS
/// release) where the archive holds it, compiled otherwise, and the miss logged; on Metal 3 by the device.
final class GPUPipelines: @unchecked Sendable {

    private static let byDevice = OSAllocatedUnfairLock<[ObjectIdentifier: GPUPipelines]>(initialState: [:])

    /// The device's pipeline maker, made on first use and kept for the process.
    static func shared(for device: MTLDevice) -> GPUPipelines {
        byDevice.withLock { makers in
            if let known = makers[ObjectIdentifier(device)] { return known }
            let made = GPUPipelines(device: device)
            makers[ObjectIdentifier(device)] = made
            return made
        }
    }

    let device: MTLDevice
    private let maker: any PipelineMaker

    private init(device: MTLDevice) {
        self.device = device
        #if !targetEnvironment(simulator)
        if #available(macOS 26, iOS 26, tvOS 26, visionOS 26, *), device.supportsFamily(.metal4),
           let compiler = try? device.makeCompiler(descriptor: MTL4CompilerDescriptor()) {
            maker = Metal4PipelineMaker(device: device, compiler: compiler)
            return
        }
        #endif
        maker = Metal3PipelineMaker(device: device)
    }

    /// `function` of `library`, specialised with `constants` (nil: a function without any), as a compute pipeline.
    /// Thread-safe; every call makes a new pipeline, so callers keep what they make.
    func make(library: MTLLibrary, function: String, constants: MTLFunctionConstantValues?,
              archive: URL?) throws -> MTLComputePipelineState {
        try maker.make(library: library, function: function, constants: constants, archive: archive)
    }
}

private protocol PipelineMaker: Sendable {
    func make(library: MTLLibrary, function: String, constants: MTLFunctionConstantValues?,
              archive: URL?) throws -> MTLComputePipelineState
}

// The simulators' SDKs have no Metal 4.
#if !targetEnvironment(simulator)
@available(macOS 26, iOS 26, tvOS 26, visionOS 26, *)
private final class Metal4PipelineMaker: PipelineMaker, @unchecked Sendable {
    private let device: MTLDevice
    private let compiler: MTL4Compiler
    /// The archives loaded so far, by file; nil for one Metal refused (built for another OS release or GPU), logged once.
    private let archives = OSAllocatedUnfairLock<[URL: Archive?]>(initialState: [:])
    /// Only read once loaded (pipelines taken from it), which Metal allows from any thread.
    private struct Archive: @unchecked Sendable { let archive: MTL4Archive }

    init(device: MTLDevice, compiler: MTL4Compiler) {
        self.device = device
        self.compiler = compiler
    }

    func make(library: MTLLibrary, function: String, constants: MTLFunctionConstantValues?,
              archive: URL?) throws -> MTLComputePipelineState {
        let named = MTL4LibraryFunctionDescriptor()
        named.name = function
        named.library = library
        let descriptor = MTL4ComputePipelineDescriptor()
        // As the archives were recorded: a specialisation only where there are constants.
        if let constants {
            let specialised = MTL4SpecializedFunctionDescriptor()
            specialised.functionDescriptor = named
            specialised.constantValues = constants
            descriptor.computeFunctionDescriptor = specialised
        } else {
            descriptor.computeFunctionDescriptor = named
        }
        guard let archive, let loaded = load(archive) else {
            return try compiler.makeComputePipelineState(descriptor: descriptor)
        }
        if let found = try? loaded.makeComputePipelineState(descriptor: descriptor) { return found }
        let start = CACurrentMediaTime()
        let made = try compiler.makeComputePipelineState(descriptor: descriptor)
        EngineLog.emit(String(format: "[GPUPipelines] %@ not in %@: compiled in %.0f ms", function,
                              archive.lastPathComponent, (CACurrentMediaTime() - start) * 1000), category: .engine)
        return made
    }

    private func load(_ url: URL) -> MTL4Archive? {
        if let known = archives.withLock({ $0[url] }) { return known?.archive }
        let result = Result { try device.makeArchive(url: try PipelineArchiveFile.unpacked(url)) }
        let loaded = (try? result.get()).map(Archive.init)
        let stored = archives.withLock { known -> Bool in
            guard known[url] == nil else { return false }
            known[url] = loaded
            return true
        }
        guard stored else { return archives.withLock { $0[url] }??.archive }
        switch result {
        case .success: EngineLog.emit("[GPUPipelines] pipeline archive \(url.lastPathComponent) loaded", category: .engine)
        case .failure(let error):
            EngineLog.emit("[GPUPipelines] pipeline archive \(url.lastPathComponent) not used: \(error.localizedDescription)",
                           category: .engine)
        }
        return loaded?.archive
    }
}
#endif

/// Metal 3 takes no Metal 4 archive: the device compiles.
private final class Metal3PipelineMaker: PipelineMaker, @unchecked Sendable {
    private let device: MTLDevice

    init(device: MTLDevice) { self.device = device }

    func make(library: MTLLibrary, function: String, constants: MTLFunctionConstantValues?,
              archive: URL?) throws -> MTLComputePipelineState {
        let made: MTLFunction?
        if let constants {
            made = try library.makeFunction(name: function, constantValues: constants)
        } else {
            made = library.makeFunction(name: function)
        }
        guard let made else { throw MTLLibraryError(.functionNotFound, userInfo: [NSLocalizedDescriptionKey: "no function \(function)"]) }
        return try device.makeComputePipelineState(function: made)
    }
}

/// A pipeline archive ships lzfse-compressed. As a raw file it is a Mach-O GPU binary, which App Store
/// signing takes for code and cannot sign, so it travels packed and is unpacked once into Caches, under
/// a name that changes with the app's build and the packed file's size. An unpacked archive is used
/// as it is.
enum PipelineArchiveFile {
    static func unpacked(_ url: URL) throws -> URL {
        guard url.pathExtension == "lzfse" else { return url }
        let fileManager = FileManager.default
        let name = url.deletingPathExtension().deletingPathExtension().lastPathComponent
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let folder = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "PipelineArchives", directoryHint: .isDirectory)
        let target = folder.appending(path: "\(name)-\(build)-\(size).metallib")
        if fileManager.fileExists(atPath: target.path) { return target }
        let archive = try (Data(contentsOf: url) as NSData).decompressed(using: .lzfse) as Data
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        try archive.write(to: target, options: .atomic)
        // The copies an earlier build unpacked are of no further use.
        for stale in (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            where stale.lastPathComponent.hasPrefix("\(name)-") && stale != target {
            try? fileManager.removeItem(at: stale)
        }
        return target
    }
}
