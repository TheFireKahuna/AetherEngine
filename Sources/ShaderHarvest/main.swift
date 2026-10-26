// shader-harvest ENGINE.metallib FEL.metallib OUT.mtl4-json: every pipeline of the engine's archive
// (EngineShaderArchive.requests), specialised from the libraries a tvOS build of the package compiled (loaded by Metal on
// the Mac), recorded by a Metal 4 compiler as a pipeline script that metal-tt translates for the TV's GPU
// (Scripts/build-shader-archive.sh).

import Foundation
import Metal
@_spi(ShaderArchive) import AetherEngine

@available(macOS 26, *)
func record(library: String, felLibrary: String, to out: String, device: MTLDevice) throws {
    let engine = try device.makeLibrary(URL: URL(fileURLWithPath: library))
    let fel = try device.makeLibrary(URL: URL(fileURLWithPath: felLibrary))
    let serializerDescriptor = MTL4PipelineDataSetSerializerDescriptor()
    serializerDescriptor.configuration = .captureDescriptors
    let serializer = device.makePipelineDataSetSerializer(descriptor: serializerDescriptor)
    let compilerDescriptor = MTL4CompilerDescriptor()
    compilerDescriptor.pipelineDataSetSerializer = serializer
    let compiler = try device.makeCompiler(descriptor: compilerDescriptor)
    let requests = EngineShaderArchive.requests(library: engine, felLibrary: fel)
    for request in requests {
        let function = MTL4LibraryFunctionDescriptor()
        function.name = request.function
        function.library = request.library
        let pipeline = MTL4ComputePipelineDescriptor()
        // As GPUPipelines asks for it: a specialisation only where there are constants.
        if let constants = request.constants {
            let specialised = MTL4SpecializedFunctionDescriptor()
            specialised.functionDescriptor = function
            specialised.constantValues = constants
            pipeline.computeFunctionDescriptor = specialised
        } else {
            pipeline.computeFunctionDescriptor = function
        }
        _ = try compiler.makeComputePipelineState(descriptor: pipeline)
    }
    try serializer.serializeAsPipelinesScript().write(to: URL(fileURLWithPath: out))
    print("recorded \(requests.count) pipelines")
}

let arguments = CommandLine.arguments
if #available(macOS 26, *), arguments.count == 4, let device = MTLCreateSystemDefaultDevice() {
    try record(library: arguments[1], felLibrary: arguments[2], to: arguments[3], device: device)
} else {
    FileHandle.standardError.write(Data("usage: shader-harvest ENGINE.metallib FEL.metallib OUT.mtl4-json (macOS 26, a Metal device)\n".utf8))
    exit(2)
}
