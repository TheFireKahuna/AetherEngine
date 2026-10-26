#include <metal_stdlib>
using namespace metal;

// ComputePass.fill on the Metal 3 backend: a dispatch, as Metal 3 fills only in a blit encoder, which would end the
// pass. `fill` is the word count and the word.
kernel void gpu_fill(device uint* words [[buffer(0)]], constant uint2& fill [[buffer(1)]],
                     uint gid [[thread_position_in_grid]]) {
    if (gid < fill.x) { words[gid] = fill.y; }
}
