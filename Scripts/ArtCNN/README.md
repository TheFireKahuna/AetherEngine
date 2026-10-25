# ArtCNN for the subtitle upscaler

Regenerates `Sources/AetherEngine/Subtitles/Upscale/ArtCNNWeights.swift` and `ArtCNNCoreMLModels.swift` from ArtCNN
(https://github.com/Artoriuz/ArtCNN, commit 0837e5326e710f49e2ab0a8d995da0708047442e, MIT). Python 3; the Core ML step
needs coremltools 8.3 and numpy.

```sh
A=path/to/ArtCNN; W=work; S=Sources/AetherEngine/Subtitles/Upscale
for m in C4F16 C4F32; do
  python3 parse_artcnn.py $A/GLSL/ArtCNN_$m.glsl $W/$m.json          # the GLSL hook's literals as layers
  python3 onnx_check.py $A/ONNX/ArtCNN_$m.onnx $W/$m.json            # they equal the ONNX initialisers
  python3 build_tiles.py $W/$m.json $W/tile_$m.mlpackage 142 718 2   # the Neural Engine tile program
done
python3 gen_weights.py $S/ArtCNNWeights.swift $W
python3 gen_coreml_swift.py $S/ArtCNNCoreMLModels.swift $W
```

The tile (142 x 718, batch 2) must match `ArtCNNCoreMLModels.tileHeight`, `tileWidth` and `batch`.
