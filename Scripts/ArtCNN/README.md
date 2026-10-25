# ArtCNN for the subtitle upscaler

Regenerates `Sources/AetherEngine/Subtitles/Upscale/ArtCNNCoreMLModels.swift` (the models the upscaler runs) and
`Tests/AetherEngineTests/ArtCNNWeights.swift` (the Float32 parameters its tests' reference reads) from ArtCNN
(https://github.com/Artoriuz/ArtCNN, commit 0837e5326e710f49e2ab0a8d995da0708047442e, MIT). Python 3; the Core ML step
needs coremltools 8.3 and numpy.

```sh
A=path/to/ArtCNN; W=work; S=Sources/AetherEngine/Subtitles/Upscale
H=46,78,142; X=256,512,1024,2048   # window heights and widths (cores plus the 7-pixel reach on each side)
for m in C4F16 C4F32; do
  python3 parse_artcnn.py $A/GLSL/ArtCNN_$m.glsl $W/$m.json       # the GLSL hook's literals as layers
  python3 onnx_check.py $A/ONNX/ArtCNN_$m.onnx $W/$m.json         # they equal the ONNX initialisers
done
for a in C4F16 C4F32; do for l in C4F16 C4F32; do                # a package per alpha / luma pairing
  python3 build_tiles.py $W/$a.json $W/$l.json $W/pair_${a}_$l.mlpackage $H $X
done; done
python3 gen_weights.py Tests/AetherEngineTests/ArtCNNWeights.swift $W
python3 gen_coreml_swift.py $S/ArtCNNCoreMLModels.swift $W $H $X
```

The window sizes are `ArtCNNCoreMLModels.windowHeights` and `windowWidths`, which `SubtitleUpscaleTilePlan` covers a
picture with.
