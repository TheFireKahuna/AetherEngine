#include <metal_stdlib>
using namespace metal;

// Subtitles drawn into the overlay's pictures while Picture in Picture shows them (OverlaySubtitles.swift).
//
// subtitle_prepare turns the cue raster (premultiplied sRGB, the way CoreGraphics draws it) into the picture's own
// coding once per cue set: Y', Cb, Cr as codes over the largest code of the picture's depth, premultiplied, and alpha.
// The two blends then put it over every picture, luma and chroma each at their own samples.

// subtitle_prepare: the picture's transfer (0 SDR, 1 PQ, 2 HLG), and whether its primaries are BT.2020.
constant uint SB_TRANSFER [[function_constant(40)]];
constant bool SB_TO_BT2020 [[function_constant(41)]];
// The blends: the largest code of the picture's depth, and the container's value of one code (10 bits sit in the high
// bits of 16: 64/65535 per code against 1/1023).
constant float SB_MAX_CODE [[function_constant(42)]];
constant float SB_CONTAINER_SCALE [[function_constant(43)]];

struct SubtitleEncoding {
    float kr;
    float kb;
    float yScale;
    float yOffset;
    float cScale;
    float cOffset;
};

static float3 srgb_to_linear(float3 v) {
    return select(pow((v + 0.055f) / 1.055f, 2.4f), v / 12.92f, v <= 0.04045f);
}

static float3 linear_to_srgb(float3 v) {
    return select(1.055f * pow(v, 1.0f / 2.4f) - 0.055f, v * 12.92f, v <= 0.0031308f);
}

// Reference white (an SDR 1.0) lands at 203 nits in PQ and at a 0.75 HLG signal, as graphics white does.
static float3 encode(float3 rgb) {
    if (SB_TRANSFER == 0) {
        if (!SB_TO_BT2020) { return rgb; }
        float3 linear = srgb_to_linear(rgb);
        linear = float3(dot(linear, float3(0.6274f, 0.3293f, 0.0433f)),
                        dot(linear, float3(0.0691f, 0.9195f, 0.0114f)),
                        dot(linear, float3(0.0164f, 0.0880f, 0.8956f)));
        return linear_to_srgb(linear);
    }
    float3 linear = srgb_to_linear(rgb);
    if (SB_TO_BT2020) {
        linear = float3(dot(linear, float3(0.6274f, 0.3293f, 0.0433f)),
                        dot(linear, float3(0.0691f, 0.9195f, 0.0114f)),
                        dot(linear, float3(0.0164f, 0.0880f, 0.8956f)));
    }
    if (SB_TRANSFER == 1) {
        float3 lm = pow(linear * (203.0f / 10000.0f), 0.1593017578125f);
        return pow((0.8359375f + 18.8515625f * lm) / (1.0f + 18.6875f * lm), 78.84375f);
    }
    float3 scene = linear * 0.26496f;
    return select(0.17883277f * log(max(12.0f * scene - 0.28466892f, 1e-6f)) + 0.55991073f, sqrt(3.0f * scene),
                  scene <= 1.0f / 12.0f);
}

kernel void subtitle_prepare(texture2d<float, access::read> raster [[texture(0)]],
                             texture2d<half, access::write> prepared [[texture(1)]],
                             constant SubtitleEncoding& coding [[buffer(0)]],
                             uint2 gid [[thread_position_in_grid]]) {
    float4 c = raster.read(gid);
    float3 rgb = encode(c.rgb / max(c.a, 1e-6f));
    float y = coding.kr * rgb.r + (1.0f - coding.kr - coding.kb) * rgb.g + coding.kb * rgb.b;
    float cb = (rgb.b - y) / (2.0f * (1.0f - coding.kb));
    float cr = (rgb.r - y) / (2.0f * (1.0f - coding.kr));
    float3 codes = float3(y * coding.yScale + coding.yOffset, float2(cb, cr) * coding.cScale + coding.cOffset);
    prepared.write(half4(half3(codes * c.a), half(c.a)), gid);
}

static float blended(float container, float overlay, float alpha) {
    float code = container / SB_CONTAINER_SCALE * (1.0f - alpha) + overlay;
    return rint(code * SB_MAX_CODE) / SB_MAX_CODE * SB_CONTAINER_SCALE;
}

kernel void subtitle_blend_luma(texture2d<float, access::read> source [[texture(0)]],
                                texture2d<float, access::write> destination [[texture(1)]],
                                texture2d<half, access::sample> prepared [[texture(2)]],
                                uint2 gid [[thread_position_in_grid]]) {
    constexpr sampler linear(filter::linear, address::clamp_to_zero, coord::normalized);
    float4 p = float4(prepared.sample(linear, (float2(gid) + 0.5f) / float2(destination.get_width(), destination.get_height())));
    destination.write(float4(blended(source.read(gid).r, p.r, p.a)), gid);
}

kernel void subtitle_blend_chroma(texture2d<float, access::read> source [[texture(0)]],
                                  texture2d<float, access::write> destination [[texture(1)]],
                                  texture2d<half, access::sample> prepared [[texture(2)]],
                                  uint2 gid [[thread_position_in_grid]]) {
    constexpr sampler linear(filter::linear, address::clamp_to_zero, coord::normalized);
    float4 p = float4(prepared.sample(linear, (float2(gid) + 0.5f) / float2(destination.get_width(), destination.get_height())));
    float2 cbcr = source.read(gid).rg;
    destination.write(float4(blended(cbcr.x, p.g, p.a), blended(cbcr.y, p.b, p.a), 0, 0), gid);
}
