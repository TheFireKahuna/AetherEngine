# ArtCNN as an fp16 MLProgram over fixed tiles: input x (N, 1, TH, TW), output y (N, 1, 2TH, 2TW), clamped.
import json, sys, numpy as np
import coremltools as ct
from coremltools.converters.mil import Builder as mb
from coremltools.converters.mil.mil import types, get_new_symbol
layers = json.load(open(sys.argv[1])); out = sys.argv[2]; th, tw = int(sys.argv[3]), int(sys.argv[4])
batches = [int(b) for b in sys.argv[5].split(',')]
Ws = [np.array(L['w'], dtype=np.float32) for L in layers]
Bs = [np.array(L['bias'], dtype=np.float32) for L in layers]
@mb.program(input_specs=[mb.TensorSpec(shape=(batches[0], 1, th, tw), dtype=types.fp16)], opset_version=ct.target.iOS16)
def prog(x):
    def conv(t, i):
        return mb.conv(x=t, weight=Ws[i].astype(np.float16), bias=Bs[i].astype(np.float16), pad_type="same")
    f0 = conv(x, 0); t = f0
    for i in range(1, 5): t = mb.relu(x=conv(t, i))
    t = mb.add(x=conv(t, 5), y=f0)
    y = mb.depth_to_space(x=conv(t, 6), block_size=2)
    return mb.clip(x=y, alpha=np.float16(0), beta=np.float16(1), name="y")
inputs = [ct.TensorType(name="x", shape=(batches[0], 1, th, tw), dtype=np.float16)]
m = ct.convert(prog, convert_to="mlprogram", inputs=inputs, minimum_deployment_target=ct.target.iOS16, compute_precision=ct.precision.FLOAT16)
m.short_description = "ArtCNN (https://github.com/Artoriuz/ArtCNN), MIT"
m.save(out); print("saved", out)
