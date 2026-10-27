import Foundation
import Metal
import CoreVideo
import os
import AetherLibavutil
import LibDeinterlace

/// The one pass between a software decoder and the display: a decoded picture, already in GPU-visible memory
/// (``DecodeFrameAllocator``), written by the GPU into a bi-planar display buffer (NV12 / P010 / NV16 / P210 /
/// P216 / NV24 / P410 / P416, the formats `SoftwareVideoDecoder.OutputFormat` names). The equations are
/// docs/colour-representation.md's, from H.273.
///
/// The source is read the way `av_read_image_line2` reads it, from the format's `AVPixFmtDescriptor`, so one
/// reader covers planar, semi-planar and packed Y'CbCr, grey, planar and packed RGB, palette, bitstream and
/// big-endian layouts. Per path:
/// - Y'CbCr with the output's chroma subsampling: each code taken to the output depth (a shift at video range,
///   H.273's (2^n - 1) scaling at full range).
/// - Y'CbCr with less chroma than the output keeps (4:2:0 into `sv22`, 4:1:1, 4:1:0, 4:4:0): chroma resampled
///   with Catmull-Rom at the stream's chroma siting, in exact integers, then taken to the output depth.
/// - Grey: luma taken to the output depth, chroma neutral (`1 << (n - 1)`).
/// - RGB and palette: R'G'B' codes decoded at their range (H.273 (27)-(29), (33)-(35)) and encoded as
///   non-constant-luminance Y'CbCr with the matrix the buffer is tagged with, 4:4:4.
/// - Convert (`ColourRepresentation`): Y'CbCr in a matrix CoreVideo cannot tag (FCC, chromaticity-derived,
///   YCgCo, YCgCo-R, GBR on Y'CbCr-labelled planes, constant luminance), chroma resampled to every pixel and
///   re-encoded 4:4:4 at the source's own depth, then taken to the output like any code of that depth.
///
/// Real-valued stages run in float32 with each value's error bound carried alongside; a code whose value lies that
/// close to a rounding tie is recomputed in double-float (inline for the affine paths, through a second dispatch for
/// constant luminance), so every code is the correctly rounded H.273 value.
/// - A source deeper than the 10 bits the output keeps: the value formed with six fraction bits and ordered
///   down with the 8x8 Bayer threshold.
///
/// Each source format gets its own specialised pipeline (function constants), compiled once per process.
