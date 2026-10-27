import Foundation
import CoreVideo
import Metal
import AetherLibavcodec
import AetherLibavutil

/// A software-decoded picture into the display buffer the player shows: libavcodec decodes into slabs
/// (``DecodeFrameAllocator``), the GPU finisher reads them and writes the buffer, tagged with the picture's colour,
/// chroma siting and HDR static metadata. The sample aspect is the caller's (playback latches one per stream, a still
/// resolves its own). Playback's software decoder and the still decoder both make their buffers here
/// (docs/software-route-gpu.md Parts 2 and 7).
///
/// Not thread-safe: the owner serialises every call (the decoder under its `lock`, the still decoder on its queue).
