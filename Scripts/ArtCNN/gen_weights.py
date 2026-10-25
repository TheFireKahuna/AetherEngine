import json, struct, base64, sys, hashlib
out = sys.argv[1]
models = {}
for m in ('C4F16', 'C4F32'):
    layers = json.load(open(sys.argv[2] + '/' + m + '.json'))
    buf = b''
    for L in layers:
        for o in range(L['cout']):
            for i in range(L['cin']):
                for y in range(3):
                    for x in range(3):
                        buf += struct.pack('<f', L['w'][o][i][y][x])
        for o in range(L['cout']):
            buf += struct.pack('<f', L['bias'][o])
    models[m] = (layers, base64.b64encode(buf).decode(), len(buf) // 4, hashlib.sha256(buf).hexdigest()[:16])
lines = []
lines.append('import Foundation')
lines.append('')
lines.append('// Generated from ArtCNN (https://github.com/Artoriuz/ArtCNN, commit 0837e5326e710f49e2ab0a8d995da0708047442e,')
lines.append('// GLSL/ArtCNN_C4F16.glsl and GLSL/ArtCNN_C4F32.glsl), MIT licensed: see ArtCNNLicense.swift.')
lines.append('// The values are the GLSL hooks\' literals read as Float32; they equal the ONNX/ArtCNN_C4F16.onnx and')
lines.append('// ONNX/ArtCNN_C4F32.onnx initialisers to within 1e-7.')
lines.append('')
lines.append('/// ArtCNN\'s trained parameters, little-endian Float32, base64. Per layer in network order, the kernel as')
lines.append('/// `[outputChannel][inputChannel][row][column]` (ONNX OIHW: row 0 is the tap above, column 0 the tap to the left)')
lines.append('/// followed by the bias `[outputChannel]`. ``ArtCNNNetwork`` decodes and checks the lengths.')
lines.append('enum ArtCNNWeights {')
for m, (layers, b64, n, h) in models.items():
    shape = ', '.join('(%d, %d)' % (L['cin'], L['cout']) for L in layers)
    lines.append('    /// %d floats, layers (in, out): %s. SHA-256 of the bytes begins %s.' % (n, shape, h))
    lines.append('    static let %s = """' % m.lower())
    for i in range(0, len(b64), 120):
        lines.append(b64[i:i+120])
    lines.append('"""')
    lines.append('')
lines[-1] = '}'
open(out, 'w').write('\n'.join(lines) + '\n')
print({m: (v[2], v[3]) for m, v in models.items()})
