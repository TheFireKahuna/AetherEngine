import Accelerate
import Foundation

/// The ArtCNN line-art models ``SubtitleUpscaler`` runs. Both are the neutral 2x luma models (not the `_DS`
/// sharpening or `_DN` denoising variants); C4F32 has twice the channels and four times the work of C4F16.
public enum ArtCNNModel: String, Sendable, CaseIterable {
    case c4f16
    case c4f32
}

/// ArtCNN C4Fxx as ArtCNN defines it (`ArtCNN_C` in the repository's Keras notebook, shipped as the mpv hooks
/// ``ArtCNNWeights`` was read from): seven 3x3 convolutions at the input resolution with zero padding,
///
///     f0 = conv0(x)                    1 -> F, no activation
///     h  = relu(conv1...conv4(f0))     F -> F, each followed by ReLU
///     h  = conv5(h) + f0               F -> F, no activation, then the residual
///     y  = depthToSpace2(conv6(h))     F -> 4, channel 2 * row + column is that 2x2 sub-pixel
///
/// and the output clamped to [0, 1] (the clamp is applied by the caller, after its own recombination).
struct ArtCNNNetwork: Sendable {
    struct Layer: Sendable {
        let inputs: Int
        let outputs: Int
        /// `[output][input][row][column]`, row 0 the tap above.
        let weights: [Float]
        let bias: [Float]

        func weight(output o: Int, input i: Int, row: Int, column: Int) -> Float {
            weights[((o * inputs + i) * 3 + row) * 3 + column]
        }
    }

    let model: ArtCNNModel
    let features: Int
    let layers: [Layer]

    static let c4f16 = ArtCNNNetwork(model: .c4f16, encoded: ArtCNNWeights.c4f16, features: 16)
    static let c4f32 = ArtCNNNetwork(model: .c4f32, encoded: ArtCNNWeights.c4f32, features: 32)

    static func network(_ model: ArtCNNModel) -> ArtCNNNetwork {
        switch model {
        case .c4f16: c4f16
        case .c4f32: c4f32
        }
    }

    private init(model: ArtCNNModel, encoded: String, features: Int) {
        guard let data = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters) else {
            preconditionFailure("ArtCNN weights are not base64")
        }
        let floats: [Float] = data.withUnsafeBytes { raw in
            (0..<(raw.count / 4)).map { Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self))) }
        }
        let shapes = [(1, features)] + Array(repeating: (features, features), count: 5) + [(features, 4)]
        var layers: [Layer] = []
        var at = 0
        for (inputs, outputs) in shapes {
            let w = inputs * outputs * 9
            layers.append(Layer(inputs: inputs, outputs: outputs, weights: Array(floats[at..<(at + w)]),
                                bias: Array(floats[(at + w)..<(at + w + outputs)])))
            at += w + outputs
        }
        precondition(at == floats.count, "ArtCNN \(model) weights: \(floats.count) floats, the network takes \(at)")
        self.model = model
        self.features = features
        self.layers = layers
    }

    /// Multiply-accumulates per input pixel.
    var macsPerPixel: Int { layers.reduce(0) { $0 + $1.inputs * $1.outputs * 9 } }

    // MARK: - Reference

    /// The network in Float32 on the CPU: im2col and one matrix product per layer. `plane` is `width` x `height`,
    /// row-major; the result is the `2width` x `2height` output before the clamp.
    func reference(plane: [Float], width: Int, height: Int) -> [Float] {
        precondition(plane.count == width * height)
        let n = width * height
        var f0 = [Float](repeating: 0, count: n * features)
        convolve(layers[0], input: plane, width: width, height: height, relu: false, into: &f0)
        var h = f0
        var next = [Float](repeating: 0, count: n * features)
        for l in 1...5 {
            convolve(layers[l], input: h, width: width, height: height, relu: l <= 4, into: &next)
            swap(&h, &next)
        }
        vDSP_vadd(h, 1, f0, 1, &h, 1, vDSP_Length(h.count))
        var sub = [Float](repeating: 0, count: n * 4)
        convolve(layers[6], input: h, width: width, height: height, relu: false, into: &sub)
        var out = [Float](repeating: 0, count: n * 4)
        for y in 0..<height {
            for x in 0..<width {
                for j in 0..<2 {
                    for i in 0..<2 {
                        out[(2 * y + j) * 2 * width + 2 * x + i] = sub[(y * width + x) * 4 + j * 2 + i]
                    }
                }
            }
        }
        return out
    }

    /// `input` and `output` are `[pixel][channel]`.
    private func convolve(_ layer: Layer, input: [Float], width: Int, height: Int, relu: Bool, into output: inout [Float]) {
        let n = width * height
        let k = layer.inputs * 9
        // columns[pixel][tap * inputs + channel], zero outside the picture: per row and tap, one strided copy of the
        // run of pixels whose tap lands inside.
        var columns = [Float](repeating: 0, count: n * k)
        columns.withUnsafeMutableBufferPointer { col in
            input.withUnsafeBufferPointer { src in
                for y in 0..<height {
                    for ky in 0..<3 {
                        let sy = y + ky - 1
                        guard sy >= 0, sy < height else { continue }
                        for kx in 0..<3 {
                            let x0 = max(0, 1 - kx), x1 = min(width, width + 1 - kx)
                            guard x1 > x0 else { continue }
                            vDSP_mmov(src.baseAddress! + (sy * width + x0 + kx - 1) * layer.inputs,
                                      col.baseAddress! + (y * width + x0) * k + (ky * 3 + kx) * layer.inputs,
                                      vDSP_Length(layer.inputs), vDSP_Length(x1 - x0), vDSP_Length(layer.inputs), vDSP_Length(k))
                        }
                    }
                }
            }
        }
        // matrix[tap * inputs + channel][output]
        var matrix = [Float](repeating: 0, count: k * layer.outputs)
        for o in 0..<layer.outputs {
            for i in 0..<layer.inputs {
                for ky in 0..<3 {
                    for kx in 0..<3 {
                        matrix[((ky * 3 + kx) * layer.inputs + i) * layer.outputs + o] = layer.weight(output: o, input: i, row: ky, column: kx)
                    }
                }
            }
        }
        vDSP_mmul(columns, 1, matrix, 1, &output, 1, vDSP_Length(n), vDSP_Length(layer.outputs), vDSP_Length(k))
        // Bias, then the ReLU, one vectorised pass per output channel.
        output.withUnsafeMutableBufferPointer { out in
            for o in 0..<layer.outputs {
                var b = layer.bias[o]
                let column = out.baseAddress! + o
                vDSP_vsadd(column, vDSP_Stride(layer.outputs), &b, column, vDSP_Stride(layer.outputs), vDSP_Length(n))
                if relu {
                    var zero: Float = 0
                    vDSP_vthr(column, vDSP_Stride(layer.outputs), &zero, column, vDSP_Stride(layer.outputs), vDSP_Length(n))
                }
            }
        }
    }
}
