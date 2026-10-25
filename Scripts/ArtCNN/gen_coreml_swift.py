import base64, sys, hashlib, json
out = sys.argv[1]; root = sys.argv[2]
lines = ['import Foundation', '',
'// Generated from ArtCNN (https://github.com/Artoriuz/ArtCNN, commit 0837e5326e710f49e2ab0a8d995da0708047442e), MIT',
'// licensed (see ArtCNNLicense.swift): the networks of ArtCNNWeights as Core ML programs (coremltools 8.3, MIL opset',
'// iOS16, Float16), built by the MIL builder from the same parameters, over a fixed tile.',
'',
'/// ArtCNN C4F16 and C4F32 as Core ML `.mlpackage`s for ``SubtitleUpscaleNeuralEngine``: input `x`, Float16',
'/// `(2, 1, 142, 718)`, two tile windows; output `y`, Float16 `(2, 1, 284, 1436)`, already clamped to [0, 1]. One',
'/// fixed shape: the Neural Engine runs each shape as its own program and switching between them costs milliseconds.',
'/// Each package is its manifest, model specification and weight blob, base64.',
'enum ArtCNNCoreMLModels {',
'    static let tileHeight = 142',
'    static let tileWidth = 718',
'    static let batch = 2',
'']
for m in ('C4F16', 'C4F32'):
    pkg = '%s/tile_%s.mlpackage' % (root, m)
    files = [('Manifest.json', 'Manifest.json'), ('Data/com.apple.CoreML/model.mlmodel', 'model'), ('Data/com.apple.CoreML/weights/weight.bin', 'weights')]
    lines.append('    static let %s: [(path: String, base64: String)] = [' % m.lower())
    for path, tag in files:
        b = open(pkg + '/' + path, 'rb').read()
        b64 = base64.b64encode(b).decode()
        lines.append('        ("%s", """' % path)
        for i in range(0, len(b64), 120): lines.append(b64[i:i+120])
        lines.append('"""),')
    lines.append('    ]')
    lines.append('')
lines[-1] = '}'
open(out, 'w').write('\n'.join(lines) + '\n')
