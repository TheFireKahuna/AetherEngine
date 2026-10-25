# ArtCNN as one fp16 multifunction MLProgram for the Neural Engine: a function per window shape "h<H>w<W>", input
# x (1, 1, H, W), output y (1, 4, H, W), the last convolution's four sub-pixel channels (channel 2 * row + column of
# the 2x block), unclamped. The composite does the depth-to-space and the clamp. The functions share one weight blob.
# Usage: build_tiles.py layers.json out.mlpackage heights widths   (comma-separated window sizes)
import json, os, sys, tempfile, numpy as np
import coremltools as ct
from coremltools.converters.mil import Builder as mb
from coremltools.converters.mil.mil import types
layers = json.load(open(sys.argv[1])); out = sys.argv[2]
heights = [int(v) for v in sys.argv[3].split(',')]; widths = [int(v) for v in sys.argv[4].split(',')]
Ws = [np.array(L['w'], dtype=np.float32) for L in layers]
Bs = [np.array(L['bias'], dtype=np.float32) for L in layers]
def program(h, w):
    @mb.program(input_specs=[mb.TensorSpec(shape=(1, 1, h, w), dtype=types.fp16)], opset_version=ct.target.iOS18)
    def prog(x):
        def conv(t, i):
            return mb.conv(x=t, weight=Ws[i].astype(np.float16), bias=Bs[i].astype(np.float16), pad_type="same")
        f0 = conv(x, 0); t = f0
        for i in range(1, 5): t = mb.relu(x=conv(t, i))
        t = mb.add(x=conv(t, 5), y=f0)
        return mb.identity(x=conv(t, 6), name="y")
    return prog
work = tempfile.mkdtemp()
desc = ct.utils.MultiFunctionDescriptor()
for h in heights:
    for w in widths:
        path = os.path.join(work, 'h%dw%d.mlpackage' % (h, w))
        m = ct.convert(program(h, w), convert_to="mlprogram", minimum_deployment_target=ct.target.iOS18,
                       compute_precision=ct.precision.FLOAT16)
        m.save(path)
        desc.add_function(path, src_function_name="main", target_function_name='h%dw%d' % (h, w))
desc.default_function_name = 'h%dw%d' % (heights[0], widths[0])
ct.utils.save_multifunction(desc, out)
print("saved", out)
