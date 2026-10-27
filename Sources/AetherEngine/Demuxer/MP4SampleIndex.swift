/// An MP4's own index of its subtitle samples and video keyframes: the sample tables in its `moov`,
/// as libavformat read them at open. Not parsed again here: the demuxer that opened the source
/// already built every stream's entries from `stts`, `stsz`, `stco` and `stsc` with the edit list
/// applied, and those entries are what `av_read_frame` reads its packets from, so a sample read where
/// an entry says is the packet the walk would get, with its time. The walk, which on an MP4 delivers
/// every video keyframe to pace itself, is then not needed for the subtitles, and an I-frame
/// rendition reads each keyframe without a demuxer of its own.
/// A subtitle track is trusted only where the entries are the whole track as libavformat delivers
/// it. They are by construction in a file that is not fragmented: `av_read_frame` reads from these
/// entries and nothing else, and only a fragmented file adds to them (its samples are listed in each
/// `moof`, read as the stream is). Not `AVStream.nb_frames`, which counts the `stts` samples, edited
/// out or not. A track with an entry the edit list marked to discard is left to the walk. A keyframe
/// needs no whole track: each entry is its sample wherever it came from, and the keyframes a segment
/// plan lists are entries the demuxer had when the plan was built.
