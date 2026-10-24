import Foundation
@testable import AetherEngine

/// Transport streams written here cell by cell around real H.264, for tests that need libavformat
/// itself to demux a TS: its parser flags the IDRs, so keyframes are the real thing.
///
/// `h264` is 50 access units (2 s at 25 fps, GOP 10, two B-frames per P), made with
///
///     ffmpeg -f lavfi -i testsrc=size=32x32:rate=25:duration=2 -pix_fmt yuv420p -c:v libx264 \
///         -profile:v main -bf 2 -g 10 -keyint_min 10 -sc_threshold 0 -preset ultrafast -crf 40 \
///         -x264-params aud=1:repeat-headers=1:b-pyramid=0 -f h264
///
/// and `matroska` is the same stream remuxed (`-c copy`) into Matroska. The composition offsets are
/// the ones ffmpeg's own mpegts muxer gave those frames.
enum TransportStreamFixture {

    static let h264 = Data(base64Encoded: """
        AAAAAQkQAAAAAWdNQArpktgIgAAAAwCAAAAZB4kSnAAAAAFozgOcgAAAAQYF//+Z3EXpvebZSLeWLNgg2SPu73gyNjQgLSBjb3JlIDE2NSByMz
        IyMiBiMzU2MDVhIC0gSC4yNjQvTVBFRy00IEFWQyBjb2RlYyAtIENvcHlsZWZ0IDIwMDMtMjAyNSAtIGh0dHA6Ly93d3cudmlkZW9sYW4ub3Jn
        L3gyNjQuaHRtbCAtIG9wdGlvbnM6IGNhYmFjPTAgcmVmPTEgZGVibG9jaz0wOjA6MCBhbmFseXNlPTA6MCBtZT1kaWEgc3VibWU9MCBwc3k9MS
        Bwc3lfcmQ9MS4wMDowLjAwIG1peGVkX3JlZj0wIG1lX3JhbmdlPTE2IGNocm9tYV9tZT0xIHRyZWxsaXM9MCA4eDhkY3Q9MCBjcW09MCBkZWFk
        em9uZT0yMSwxMSBmYXN0X3Bza2lwPTEgY2hyb21hX3FwX29mZnNldD0wIHRocmVhZHM9MSBsb29rYWhlYWRfdGhyZWFkcz0xIHNsaWNlZF90aH
        JlYWRzPTAgbnI9MCBkZWNpbWF0ZT0xIGludGVybGFjZWQ9MCBibHVyYXlfY29tcGF0PTAgY29uc3RyYWluZWRfaW50cmE9MCBiZnJhbWVzPTIg
        Yl9weXJhbWlkPTAgYl9hZGFwdD0wIGJfYmlhcz0wIGRpcmVjdD0xIHdlaWdodGI9MCBvcGVuX2dvcD0wIHdlaWdodHA9MCBrZXlpbnQ9MTAga2
        V5aW50X21pbj02IHNjZW5lY3V0PTAgaW50cmFfcmVmcmVzaD0wIHJjPWNyZiBtYnRyZWU9MCBjcmY9NDAuMCBxY29tcD0wLjYwIHFwbWluPTAg
        cXBtYXg9NjkgcXBzdGVwPTQgaXBfcmF0aW89MS40MCBwYl9yYXRpbz0xLjMwIGFxPTAAgAAAAWWIhAHQYwAPho96hyYaos/qMAEbf8rwv8mB4i
        S/ZDxGAx88eQIZ7n4YgGCQwOOwVsjItzDXB5YeWAA1ZJg6Z/z95XvH1TAiBMFoEwGMANB8u5EGNcUAy/8HRll18Jfz6YAZvYqz/m+C6fWjIM/d
        8MIUATCCoqDuIXZhmhivLByxNM40hBh/oGeXri0CYLQJgLOAKyCgkJ8pJMv9fcANB2Sk3l7/IhJcpAYQrkJSNRY3wsvYDJSwOAASgKEAAXoJHB
        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
        sAAAAAEJUAAAAQGekIGIsA==
        """, options: .ignoreUnknownCharacters)!

    static let matroska = Data(base64Encoded: """
        GkXfo6NChoEBQveBAULygQRC84EIQoKIbWF0cm9za2FCh4EEQoWBAhhTgGcBAAAAAAAOJRFNm3TAv4TTVm5fTbuLU6uEFUmpZlOsgaFNu4tTq4
        QWVK5rU6yB7027jFOrhBJUw2dTrIIBiE27jFOrhBxTu2tTrIINvewBAAAAAAAAUwAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
        AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAFUmpZsm/hCAVjUcq17GDD0JATYCMTGF2ZjYzLjEuMTAyV0
        GMTGF2ZjYzLjEuMTAyc6SQrMF+PXTnD4mHSXZ5GiMVS0SJiECfQAAAAAAAFlSua0CTv4SscdD2rgEAAAAAAACE14EBc8WIM9+7AWVmkz2cgQAi
        tZyDdW5kiIEAho9WX01QRUc0L0lTTy9BVkODgQEj44OEAmJaAOCUsIEguoEgmoECVbCIVbeBAVW4gQJV7oEA7AEAAAAAAAACAABjoqUBTUAK/+
        EAFWdNQArpktgIgAAAAwCAAAAZB4kSnAEABWjOA5yAElTDZ92/hHnSIJtzc59jwIBnyJlFo4dFTkNPREVSRIeMTGF2ZjYzLjEuMTAyc3OyY8CL
        Y8WIM9+7AWVmkz1nyKFFo4hEVVJBVElPTkSHkzAwOjAwOjAyLjAwMDAwMDAwMAAfQ7Z1S82/hPkMnHjngQCjQ+CBAACAAAAAAgkQAAAAFWdNQA
        rpktgIgAAAAwCAAAAZB4kSnAAAAAVozgOcgAAAAp0GBf//mdxF6b3m2Ui3lizYINkj7u94MjY0IC0gY29yZSAxNjUgcjMyMjIgYjM1NjA1YSAt
        IEguMjY0L01QRUctNCBBVkMgY29kZWMgLSBDb3B5bGVmdCAyMDAzLTIwMjUgLSBodHRwOi8vd3d3LnZpZGVvbGFuLm9yZy94MjY0Lmh0bWwgLS
        BvcHRpb25zOiBjYWJhYz0wIHJlZj0xIGRlYmxvY2s9MDowOjAgYW5hbHlzZT0wOjAgbWU9ZGlhIHN1Ym1lPTAgcHN5PTEgcHN5X3JkPTEuMDA6
        MC4wMCBtaXhlZF9yZWY9MCBtZV9yYW5nZT0xNiBjaHJvbWFfbWU9MSB0cmVsbGlzPTAgOHg4ZGN0PTAgY3FtPTAgZGVhZHpvbmU9MjEsMTEgZm
        FzdF9wc2tpcD0xIGNocm9tYV9xcF9vZmZzZXQ9MCB0aHJlYWRzPTEgbG9va2FoZWFkX3RocmVhZHM9MSBzbGljZWRfdGhyZWFkcz0wIG5yPTAg
        ZGVjaW1hdGU9MSBpbnRlcmxhY2VkPTAgYmx1cmF5X2NvbXBhdD0wIGNvbnN0cmFpbmVkX2ludHJhPTAgYmZyYW1lcz0yIGJfcHlyYW1pZD0wIG
        JfYWRhcHQ9MCBiX2JpYXM9MCBkaXJlY3Q9MSB3ZWlnaHRiPTAgb3Blbl9nb3A9MCB3ZWlnaHRwPTAga2V5aW50PTEwIGtleWludF9taW49NiBz
        Y2VuZWN1dD0wIGludHJhX3JlZnJlc2g9MCByYz1jcmYgbWJ0cmVlPTAgY3JmPTQwLjAgcWNvbXA9MC42MCBxcG1pbj0wIHFwbWF4PTY5IHFwc3
        RlcD00IGlwX3JhdGlvPTEuNDAgcGJfcmF0aW89MS4zMCBhcT0wAIAAAAEPZYiEAdBjAA+Gj3qHJhqiz+owARt/yvC/yYHiJL9kPEYDHzx5Ahnu
        fhiAYJDA47BWyMi3MNcHlh5YADVkmDpn/P3le8fVMCIEwWgTAYwA0Hy7kQY1xQDL/wdGWXXwl/PpgBm9irP+b4Lp9aMgz93wwhQBMIKioO4hdm
        GaGK8sHLE0zjSEGH+gZ5euLQJgtAmAs4ArIKCQnykky/19wA0HZKTeXv8iElykBhCuQlI1FjfCy9gMlLA4ABKAoQABegkcFhEoEPQNQ+cBqQju
        UAIu6huf4FnAAueUBu7AiLE09v4Aw3omdV4XRCy6cquW/kFPsB0xywhAGgYWra3MBV3K0JNhk3DlHPYHOvKMCDqfQKOUgQB4AAAAAAIJMAAAAA
        ZBmiYBBFijlIEAKAAAAAACCVAAAAAGAZ5CgKIso5SBAFAAAAAAAglQAAAABgGeRICiLKOYgQDwAAAAAAIJMAAAAApBmkwCk+r/Uw2Ao5SBAKAA
        AAAAAglQAAAABgGeaICSLKOUgQDIAAAAAAIJUAAAAAYBnmqAgiyjn4EBaAAAAAACCTAAAAARQZpyBk+G4vyiQ/tn/gjivuajlIEBGAAAAAACCV
        AAAAAGAZ6Ogciwo5SBAUAAAAAAAglQAAAABgGekIGIsKNA6YEBkIAAAAACCRAAAAAVZ01ACumS2AiAAAADAIAAABkHiRKcAAAABWjOA5yAAAAA
        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
        """, options: .ignoreUnknownCharacters)!

    struct AccessUnit {
        var bytes: [UInt8]
        /// PTS minus DTS, in 90 kHz ticks.
        var compositionOffset: Int64
        var isKey: Bool
    }

    /// `h264` split at its access unit delimiters, in decode order.
    static let accessUnits: [AccessUnit] = {
        let bytes = [UInt8](h264)
        var starts: [Int] = []
        var i = 0
        while i + 4 < bytes.count {
            if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 0, bytes[i + 3] == 1, bytes[i + 4] & 0x1F == 9 {
                starts.append(i)
            }
            i += 1
        }
        let pattern: [Int64] = [1, 3, 0, 0, 3, 0, 0, 3, 0, 0]
        return starts.indices.map { k in
            let end = k + 1 < starts.count ? starts[k + 1] : bytes.count
            return AccessUnit(bytes: Array(bytes[starts[k]..<end]), compositionOffset: pattern[k % 10] * 3600,
                              isKey: k % 10 == 0)
        }
    }()

    static let frameTicks: Int64 = 3600
    static let pmtPID = 0x100

    /// A run of the stream under one PMT.
    struct Program {
        var frames: Int
        var videoPID = 0x1011
        /// The PMT's stream_type for the video: 0x1B H.264, 0x24 HEVC.
        var videoStreamType: UInt8 = 0x1B
        var pmtVersion: UInt8 = 0
        /// The PMT's stream_identifier_descriptor tag for the video, which libavformat matches a
        /// changed PMT's streams by when it merges versions.
        var componentTag: UInt8?
    }

    struct Written {
        var data: Data
        /// Every keyframe's PES: where its first cell is and its decode time.
        var keyframes: [(pos: Int64, dts: Int64)]
        /// Every frame's decode and presentation time, in order.
        var frames: [(dts: Int64, pts: Int64)]
    }

    /// `programs` one after the other, the frames cycling through `accessUnits` from `startingAt`
    /// (a start past 0 is mid-GOP, as a DVR recording starts), each frame enlarged by `padding` bytes
    /// of filler NAL so the stream has a size seeks can be measured on.
    static func write(_ programs: [Program], startingAt start: Int = 0, firstDTS: Int64 = 900_000,
                      padding: Int = 0) -> Written {
        var w = Writer()
        var keyframes: [(pos: Int64, dts: Int64)] = []
        var frames: [(dts: Int64, pts: Int64)] = []
        var frame = 0
        for program in programs {
            for k in 0..<program.frames {
                if k % 25 == 0 {
                    w.section(pid: 0, [0x00, 0xB0, 13, 0x00, 0x01, 0xC1, 0x00, 0x00, 0x00, 0x01,
                                       0xE0 | UInt8(pmtPID >> 8), UInt8(pmtPID & 0xFF)])
                    w.section(pid: pmtPID, pmt(program))
                }
                let unit = accessUnits[(start + frame) % accessUnits.count]
                let dts = firstDTS + Int64(frame) * frameTicks
                let pts = dts + unit.compositionOffset
                var payload = unit.bytes
                if padding > 0 { payload += [0, 0, 0, 1, 0x0C] + [UInt8](repeating: 0xFF, count: padding) + [0x80] }
                if unit.isKey { keyframes.append((Int64(w.bytes.count), dts)) }
                frames.append((dts, pts))
                let pes = Writer.pes(streamID: 0xE0, pts: pts, dts: dts, payload: payload)
                var at = 0
                var first = true
                while at < pes.count {
                    let adaptation = first ? Writer.pcrAdaptation(dts - 3000, randomAccess: unit.isKey) : nil
                    let room = 184 - (adaptation.map { $0.count + 1 } ?? 0)
                    let n = min(room, pes.count - at)
                    w.cell(pid: program.videoPID, start: first, adaptation: adaptation, payload: pes[at..<at + n])
                    at += n
                    first = false
                }
                frame += 1
            }
        }
        return Written(data: Data(w.bytes), keyframes: keyframes, frames: frames)
    }

    private static func pmt(_ program: Program) -> [UInt8] {
        let descriptors: [UInt8] = program.componentTag.map { [0x52, 1, $0] } ?? []
        let body: [UInt8] = [0x00, 0x01, 0xC1 | (program.pmtVersion & 0x1F) << 1, 0x00, 0x00,
                             0xE0 | UInt8(program.videoPID >> 8), UInt8(program.videoPID & 0xFF), 0xF0, 0x00,
                             program.videoStreamType, 0xE0 | UInt8(program.videoPID >> 8), UInt8(program.videoPID & 0xFF),
                             0xF0, UInt8(descriptors.count)] + descriptors
        return [0x02, 0xB0 | UInt8(((body.count + 4) >> 8) & 0x0F), UInt8((body.count + 4) & 0xFF)] + body
    }

    /// 188-byte cells, continuity counted per PID, the last cell of a PES stuffed in its adaptation field.
    struct Writer {
        private(set) var bytes: [UInt8] = []
        private var cc: [Int: UInt8] = [:]

        mutating func cell(pid: Int, start: Bool, adaptation: [UInt8]? = nil, payload: ArraySlice<UInt8>) {
            let needsAdaptation = adaptation != nil || payload.count < 184
            let counter = cc[pid] ?? 0
            cc[pid] = (counter + 1) & 0x0F
            var out: [UInt8] = [0x47, (start ? 0x40 : 0) | UInt8((pid >> 8) & 0x1F), UInt8(pid & 0xFF),
                                UInt8(needsAdaptation ? 0x30 : 0x10) | counter]
            if needsAdaptation {
                let length = 183 - payload.count
                out.append(UInt8(length))
                if length > 0 {
                    let body = adaptation ?? [0x00]
                    out += body + [UInt8](repeating: 0xFF, count: length - body.count)
                }
            }
            out += payload
            bytes += out
        }

        mutating func section(pid: Int, _ section: [UInt8]) {
            var payload: [UInt8] = [0x00] + section + Self.crc32(section)
            payload += [UInt8](repeating: 0xFF, count: 184 - payload.count)
            cell(pid: pid, start: true, payload: payload[...])
        }

        static func crc32(_ bytes: [UInt8]) -> [UInt8] {
            var crc: UInt32 = 0xFFFF_FFFF
            for byte in bytes {
                crc ^= UInt32(byte) << 24
                for _ in 0..<8 { crc = crc & 0x8000_0000 != 0 ? (crc << 1) ^ 0x04C1_1DB7 : crc << 1 }
            }
            return [UInt8(crc >> 24), UInt8((crc >> 16) & 0xFF), UInt8((crc >> 8) & 0xFF), UInt8(crc & 0xFF)]
        }

        static func timestamp(_ prefix: UInt8, _ ts: Int64) -> [UInt8] {
            let v = UInt64(ts) & ((1 << 33) - 1)
            return [(prefix << 4) | UInt8((v >> 29) & 0x0E) | 1, UInt8((v >> 22) & 0xFF),
                    UInt8((v >> 14) & 0xFE) | 1, UInt8((v >> 7) & 0xFF), UInt8((v << 1) & 0xFE) | 1]
        }

        /// A video PES: unbounded, PTS and DTS.
        static func pes(streamID: UInt8, pts: Int64, dts: Int64, payload: [UInt8]) -> [UInt8] {
            let header: [UInt8] = [0x84, 0xC0, 10] + timestamp(3, pts) + timestamp(1, dts)
            return [0, 0, 1, streamID, 0, 0] + header + payload
        }

        static func pcrAdaptation(_ base: Int64, randomAccess: Bool) -> [UInt8] {
            let b = UInt64(base) & ((1 << 33) - 1)
            return [(randomAccess ? 0x40 : 0) | 0x10, UInt8((b >> 25) & 0xFF), UInt8((b >> 17) & 0xFF),
                    UInt8((b >> 9) & 0xFF), UInt8((b >> 1) & 0xFF), UInt8((b & 1) << 7) | 0x7E, 0x00]
        }
    }
}

/// A reader over bytes in memory that counts what is read from it.
final class CountingDataReader: IOReader, @unchecked Sendable {
    private let base: DataIOReader
    private let lock = NSLock()
    private var read = 0

    init(_ data: Data) { base = DataIOReader(data: data) }

    var bytesRead: Int { lock.lock(); defer { lock.unlock() }; return read }

    func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 {
        let got = base.read(buffer, size: size)
        if got > 0 { lock.lock(); read += Int(got); lock.unlock() }
        return got
    }
    func seek(offset: Int64, whence: Int32) -> Int64 { base.seek(offset: offset, whence: whence) }
    func close() { base.close() }
    func cancel() {}
    func makeIndependentReader() -> IOReader? { base.makeIndependentReader() }
    var discImageProbeEnabled: Bool { false }
}
