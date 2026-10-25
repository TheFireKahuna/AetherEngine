# Embeds the multifunction pair packages build_tiles.py made (<root>/pair_<alpha>_<luma>.mlpackage for each pairing of
# C4F16 and C4F32) as ArtCNNCoreMLModels.swift. Usage: gen_coreml_swift.py out.swift root heights widths
import base64, sys
out, root = sys.argv[1], sys.argv[2]
heights, widths = sys.argv[3], sys.argv[4]
lines = ['import Foundation', '',
'// Generated from ArtCNN (https://github.com/Artoriuz/ArtCNN, commit 0837e5326e710f49e2ab0a8d995da0708047442e), MIT',
'// licensed (see ArtCNNLicense.swift): the networks of ArtCNNWeights as Core ML multifunction programs (coremltools',
'// 8.3, MIL opset iOS18, Float16), built by the MIL builder from the same parameters (Scripts/ArtCNN).',
'',
'/// ArtCNN as Core ML `.mlpackage`s for ``SubtitleUpscaleNeuralEngine``, one per pairing of an alpha and a luma network,',
'/// both planes of a window in one call: function `h<H>w<W>` takes `xa` and `xl`, Float16 `(1, 1, H, W)`, and gives `ya`',
'/// and `yl`, Float16 `(1, 4, H, W)`, each network\'s last convolution\'s four sub-pixel channels (channel `2 * row +',
'/// column` of each 2x block), unclamped. Fixed shapes because Core ML runs a flexible shape on the Neural Engine only',
'/// at its default size, or re-optimises it for milliseconds at each change; the functions of one package share its',
'/// weights and switch for free. Each package is its manifest, model specification and weight blob, base64.',
'enum ArtCNNCoreMLModels {',
'    /// Window heights and widths, each a core plus the network\'s 7-pixel reach on both sides; the widths keep',
'    /// every row a multiple of 64 bytes.',
'    static let windowHeights = [%s]' % heights.replace(',', ', '),
'    static let windowWidths = [%s]' % widths.replace(',', ', '),
'',
'    static func package(alpha: ArtCNNModel, luma: ArtCNNModel) -> [(path: String, base64: String)] {',
'        switch (alpha, luma) {',
'        case (.c4f16, .c4f16): c4f16c4f16',
'        case (.c4f32, .c4f32): c4f32c4f32',
'        case (.c4f16, .c4f32): c4f16c4f32',
'        case (.c4f32, .c4f16): c4f32c4f16',
'        }',
'    }',
'']
for a in ('C4F16', 'C4F32'):
    for l in ('C4F16', 'C4F32'):
        pkg = '%s/pair_%s_%s.mlpackage' % (root, a, l)
        files = ['Manifest.json', 'Data/com.apple.CoreML/model.mlmodel', 'Data/com.apple.CoreML/weights/weight.bin']
        lines.append('    private static let %s%s: [(path: String, base64: String)] = [' % (a.lower(), l.lower()))
        for path in files:
            b64 = base64.b64encode(open(pkg + '/' + path, 'rb').read()).decode()
            lines.append('        ("%s", """' % path)
            for i in range(0, len(b64), 120): lines.append(b64[i:i+120])
            lines.append('"""),')
        lines.append('    ]')
        lines.append('')
lines[-1] = '}'
open(out, 'w').write('\n'.join(lines) + '\n')
