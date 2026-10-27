// Tests/AetherEngineTests/IFrameKeyframeReaderTests.swift
import Foundation
import Testing
import AetherLibavcodec
@testable import AetherEngine

/// The I-frame keyframe reader against libavformat itself: a keyframe read from the index (Matroska's
/// Cues, an MP4's sample entries) or by a demuxer of its own (any other container) is the packet
/// `av_read_frame` hands over for it. The route follows what the index covers, a failure cools down,
/// and interrupt and close end it.
///
/// The fixtures were made with ffmpeg 8, a 32x32 testsrc2 of 2.4 s at 10 fps with a keyframe every 6
/// frames and B-frames, so composition times differ from decode times:
///
///     ffmpeg -f lavfi -i testsrc2=size=32x32:rate=10 -t 2.4 -c:v libx264 -preset ultrafast -crf 40 \
///         -g 6 -keyint_min 6 -sc_threshold 0 -pix_fmt yuv420p -bf 2 kf.mkv
///     ffmpeg -i kf.mkv -c copy kf.mp4
///     ffmpeg -i kf.mkv -c copy -flvflags add_keyframe_index kf.flv
@Suite("I-frame keyframe reader", .serialized)
struct IFrameKeyframeReaderTests {

    static let mkv = Data(base64Encoded: """
        GkXfo6NChoEBQveBAULygQRC84EIQoKIbWF0cm9za2FCh4EEQoWBAhhTgGcBAAAAAAAKPBFNm3TAv4SW3T6QTbuLU6uEFUmpZlOsgaFNu4tTq4QW
        VK5rU6yB7027jFOrhBJUw2dTrIIBhk27jFOrhBxTu2tTrIIJ5+wBAAAAAAAAUwAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
        AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAFUmpZsm/hB0RcAEq17GDD0JATYCMTGF2ZjYzLjEuMTAyV0GMTGF2
        ZjYzLjEuMTAyc6SQpT2s5z4865p+Lqw17H27w0SJiECiwAAAAAAAFlSua0CRv4SdTRY1rgEAAAAAAACC14EBc8WIhYVKKkLuq6acgQAitZyDdW5k
        iIEAho9WX01QRUc0L0lTTy9BVkODgQEj44OEBfXhAOCQsIEguoEgmoECVbCEVbmBAVXugQDsAQAAAAAAAAIAAGOipwFNQAr/4QAXZ01ACuyktgIg
        AAADACAAAAMCgeJEssABAAVozgOcgBJUw2dAgb+E38SeIHNzn2PAgGfImUWjh0VOQ09ERVJEh4xMYXZmNjMuMS4xMDJzc9ZjwItjxYiFhUoqQu6r
        pmfIoUWjh0VOQ09ERVJEh5RMYXZjNjMuMS4xMDIgbGlieDI2NGfIoUWjiERVUkFUSU9ORIeTMDA6MDA6MDIuNDAwMDAwMDAwAB9DtnVH1L+ETtqZ
        9ueBAKNDroEAAIAAAAKcBgX//5jcRem95tlIt5Ys2CDZI+7veDI2NCAtIGNvcmUgMTY1IHIzMjIyIGIzNTYwNWEgLSBILjI2NC9NUEVHLTQgQVZD
        IGNvZGVjIC0gQ29weWxlZnQgMjAwMy0yMDI1IC0gaHR0cDovL3d3dy52aWRlb2xhbi5vcmcveDI2NC5odG1sIC0gb3B0aW9uczogY2FiYWM9MCBy
        ZWY9MSBkZWJsb2NrPTA6MDowIGFuYWx5c2U9MDowIG1lPWRpYSBzdWJtZT0wIHBzeT0xIHBzeV9yZD0xLjAwOjAuMDAgbWl4ZWRfcmVmPTAgbWVf
        cmFuZ2U9MTYgY2hyb21hX21lPTEgdHJlbGxpcz0wIDh4OGRjdD0wIGNxbT0wIGRlYWR6b25lPTIxLDExIGZhc3RfcHNraXA9MSBjaHJvbWFfcXBf
        b2Zmc2V0PTAgdGhyZWFkcz0xIGxvb2thaGVhZF90aHJlYWRzPTEgc2xpY2VkX3RocmVhZHM9MCBucj0wIGRlY2ltYXRlPTEgaW50ZXJsYWNlZD0w
        IGJsdXJheV9jb21wYXQ9MCBjb25zdHJhaW5lZF9pbnRyYT0wIGJmcmFtZXM9MiBiX3B5cmFtaWQ9MiBiX2FkYXB0PTAgYl9iaWFzPTAgZGlyZWN0
        PTEgd2VpZ2h0Yj0wIG9wZW5fZ29wPTAgd2VpZ2h0cD0wIGtleWludD02IGtleWludF9taW49NCBzY2VuZWN1dD0wIGludHJhX3JlZnJlc2g9MCBy
        Yz1jcmYgbWJ0cmVlPTAgY3JmPTQwLjAgcWNvbXA9MC42MCBxcG1pbj0wIHFwbWF4PTY5IHFwc3RlcD00IGlwX3JhdGlvPTEuNDAgcGJfcmF0aW89
        MS4zMCBhcT0wAIAAAAEGZYiEAOgxgA0yyPjBgKP4c4uy8AY9c+fYSEyOgjJi9uL/4jd77gTYOtZB4+w3NlIb6K95h461oPNmz0N9IzlDssCAkESB
        gUMATZxEOGxdQmhg54tRWQ4bgnZth9EUMIY/BLbeNFAXwBHcdXm5XA9/4eGZFQfSGJXrpsruh4TNZXSwm699TXtHnpiLtMC+qsfSqufWMnVqBhTP
        K2kg9HmjKqtPvkyq6AYAMAyc9CufQK2DD6Lf/OG140fvOG2Xbzw3zFWupR/s/f3neu5/9+Bhw5wAHQ+x2fYv/z7Fn2L8aBiBFvMC5HMC5FqgeJDq
        gWJBfHsYA0z+7//e/g8AoPP/+sHyw2B5YqOfgQEsAAAAABdBmiMDLzwhZsiASjM2MGHAmGiGv44XyaOVgQBkAAAAAA1BnkFAQs8UNCDYv/5Io5iB
        AMgAAAAAEAGeYkDFnqCQXZv02NN/ckCjlIEB9AAAAAAMQZplNEp68EOb+SCSo46BAZAAAAAABgGehECEWKNA2oECWIAAAADSZYiCAKDGAHfHYw4+
        DnC/pSJv77h8mTwmZv53OV0qda0HljOUOyw7vYeyWIneOyx+ECJA4VkCGzaNeoIjmf/pKqGigBMKoSO2b/bnyIMrl1FZBfAEd94r+oOHCZKj8Je5
        9x0ItdhAJ9+/+Eds+GJzYybNZu2idbtGBjatR8i9TtGb6UbtgwDASdUpY9ZrhoaWfvOI7ON84pPNSIlkjSfRJq3Z+8+GHA/AOi+v+tfiJRCH74To
        j7A7wPsDvAW7KBoBwDHAZZUC/AcqA/g2BaUGwHSho46BA4QAAAAABkGaIwMiwKOOgQK8AAAAAAZBnkFAQiyjjoEDIAAAAAAGAZ5iQKRYo5GBBEwA
        AAAACUGaZTRKdJ9aqKOOgQPoAAAAAAYBnoRAhFijQNuBBLCAAAAA02WIhAKDGAMpnZgDF/Qc4X9KRN/fcPkyeEzF/PuMrpWtR8UTOUOyyos+ZLET
        njssnOh3rxgAMKyBDZuGvUEqDXK8NcAJhVCR2zf7c+RvJPHaCYL4Ajp7xWqoUOEyVH4S9z7joRa7CAT79/8I7Z8MTmwybNrro3JrdowMbVqPkWan
        aGb6aq6BgYCR00pY9ZrhoaWfvOI7ON84pPNSIlkjSfRJq3Z+8+GHA/AOi+v/Wvx8Qh1NzBmPnlyfws/CxjsoGgHAMcBllQL8ByoD+DYFpQbAdKGj
        lYEF3AAAAAANQZojAy9erngLYhl+oKOOgQUUAAAAAAZBnkFAQiyjjoEFeAAAAAAGAZ5iQKRYo5eBBqQAAAAAD0GaZTRKdJ8NYritYdHv6qOOgQZA
        AAAAAAYBnoRAhFijQNWBBwiAAAAAzWWIggCgxgBr0dmAM/Bzhf0pE399w+TJ4TMX8+4yulZ3QeWc6HevmOw9ksRO8dlj8IESA4VkCGzcNeoHZhQC
        YBMKoSO2b/bnySsQY8uiKyC+AI77xVVUFDhMlR+Evc+46EWuwgE+/f/CO2fDE5sZNms3bROt2jAxtWo+Rep2jN9KN2wYBgNHTSlj1muGhpZ+84js
        43zik81IiWSNJ9Emrdn7z4YcCLYA0ul9f9a/CUYQhDh/3LD/uQn8B3gfg+AtVQ9UAwYSR//CfsNgfYijkIEINAAAAAAIQZojAyfUpVCjjoEHbAAA
        AAAGQZ5BQEIso46BB9AAAAAABgGeYkCkWKOYgQj8AAAAABBBmmU0SnSfDmK8pYzrdX1Ao46BCJgAAAAABgGehECEWBxTu2vQv4RZB593u4+zgQC3
        iveBAfGCAg3wgQm7kbOCAli3i/eBAfGCAg3wggQyu5GzggSwt4v3gQHxggIN8IIFYruRs4IHCLeL94EB8YICDfCCBqA=
        """, options: .ignoreUnknownCharacters)!

    static let mp4 = Data(base64Encoded: """
        AAAAIGZ0eXBpc29tAAACAGlzb21pc28yYXZjMW1wNDEAAAAIZnJlZQAABz9tZGF0AAACnAYF//+Y3EXpvebZSLeWLNgg2SPu73gyNjQgLSBjb3Jl
        IDE2NSByMzIyMiBiMzU2MDVhIC0gSC4yNjQvTVBFRy00IEFWQyBjb2RlYyAtIENvcHlsZWZ0IDIwMDMtMjAyNSAtIGh0dHA6Ly93d3cudmlkZW9s
        YW4ub3JnL3gyNjQuaHRtbCAtIG9wdGlvbnM6IGNhYmFjPTAgcmVmPTEgZGVibG9jaz0wOjA6MCBhbmFseXNlPTA6MCBtZT1kaWEgc3VibWU9MCBw
        c3k9MSBwc3lfcmQ9MS4wMDowLjAwIG1peGVkX3JlZj0wIG1lX3JhbmdlPTE2IGNocm9tYV9tZT0xIHRyZWxsaXM9MCA4eDhkY3Q9MCBjcW09MCBk
        ZWFkem9uZT0yMSwxMSBmYXN0X3Bza2lwPTEgY2hyb21hX3FwX29mZnNldD0wIHRocmVhZHM9MSBsb29rYWhlYWRfdGhyZWFkcz0xIHNsaWNlZF90
        aHJlYWRzPTAgbnI9MCBkZWNpbWF0ZT0xIGludGVybGFjZWQ9MCBibHVyYXlfY29tcGF0PTAgY29uc3RyYWluZWRfaW50cmE9MCBiZnJhbWVzPTIg
        Yl9weXJhbWlkPTIgYl9hZGFwdD0wIGJfYmlhcz0wIGRpcmVjdD0xIHdlaWdodGI9MCBvcGVuX2dvcD0wIHdlaWdodHA9MCBrZXlpbnQ9NiBrZXlp
        bnRfbWluPTQgc2NlbmVjdXQ9MCBpbnRyYV9yZWZyZXNoPTAgcmM9Y3JmIG1idHJlZT0wIGNyZj00MC4wIHFjb21wPTAuNjAgcXBtaW49MCBxcG1h
        eD02OSBxcHN0ZXA9NCBpcF9yYXRpbz0xLjQwIHBiX3JhdGlvPTEuMzAgYXE9MACAAAABBmWIhADoMYANMsj4wYCj+HOLsvAGPXPn2EhMjoIyYvbi
        /+I3e+4E2DrWQePsNzZSG+iveYeOtaDzZs9DfSM5Q7LAgJBEgYFDAE2cRDhsXUJoYOeLUVkOG4J2bYfRFDCGPwS23jRQF8AR3HV5uVwPf+HhmRUH
        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
        """, options: .ignoreUnknownCharacters)!

    static let flv = Data(base64Encoded: """
        RkxWAQEAAAAJAAAAABIAAgcAAAAAAAAAAgAKb25NZXRhRGF0YQgAAAAUAAhkdXJhdGlvbgBABMzMzMzMzQAFd2lkdGgAQEAAAAAAAAAABmhlaWdo
        dABAQAAAAAAAAAANdmlkZW9kYXRhcmF0ZQAAAAAAAAAAAAAJZnJhbWVyYXRlAEAkAAAAAAAAAAx2aWRlb2NvZGVjaWQAQBwAAAAAAAAAB2VuY29k
        ZXICAAxMYXZmNjMuMS4xMDIACGZpbGVzaXplAECnEgAAAAAAAAhoYXNWaWRlbwEBAAxoYXNLZXlmcmFtZXMBAQAIaGFzQXVkaW8BAAALaGFzTWV0
        YWRhdGEBAQAMY2FuU2Vla1RvRW5kAQEACGRhdGFzaXplAECjLAAAAAAAAAl2aWRlb3NpemUAQKIuAAAAAAAACWF1ZGlvc2l6ZQAAAAAAAAAAAAAN
        bGFzdHRpbWVzdGFtcABAAmZmZmZmZgAVbGFzdGtleWZyYW1ldGltZXN0YW1wAD/8zMzMzMzNABRsYXN0a2V5ZnJhbWVsb2NhdGlvbgBAowYAAAAA
        AAAJa2V5ZnJhbWVzAwANZmlsZXBvc2l0aW9ucwoAAAAEAECC8AAAAAAAAECbaAAAAAAAAECgugAAAAAAAECj3AAAAAAAAAV0aW1lcwoAAAAEAAAA
        AAAAAAAAAD/jMzMzMzMzAD/zMzMzMzMzAD/8zMzMzMzNAAAJAAAJAAACEgkAACwAAAAAAAAAFwAAAAABTUAK/+EAF2dNQArspLYCIAAAAwAgAAAD
        AoHiRLLAAQAFaM4DnIAAAAA3CQADrwAAAAAAAAAXAQAAyAAAApwGBf//mNxF6b3m2Ui3lizYINkj7u94MjY0IC0gY29yZSAxNjUgcjMyMjIgYjM1
        NjA1YSAtIEguMjY0L01QRUctNCBBVkMgY29kZWMgLSBDb3B5bGVmdCAyMDAzLTIwMjUgLSBodHRwOi8vd3d3LnZpZGVvbGFuLm9yZy94MjY0Lmh0
        bWwgLSBvcHRpb25zOiBjYWJhYz0wIHJlZj0xIGRlYmxvY2s9MDowOjAgYW5hbHlzZT0wOjAgbWU9ZGlhIHN1Ym1lPTAgcHN5PTEgcHN5X3JkPTEu
        MDA6MC4wMCBtaXhlZF9yZWY9MCBtZV9yYW5nZT0xNiBjaHJvbWFfbWU9MSB0cmVsbGlzPTAgOHg4ZGN0PTAgY3FtPTAgZGVhZHpvbmU9MjEsMTEg
        ZmFzdF9wc2tpcD0xIGNocm9tYV9xcF9vZmZzZXQ9MCB0aHJlYWRzPTEgbG9va2FoZWFkX3RocmVhZHM9MSBzbGljZWRfdGhyZWFkcz0wIG5yPTAg
        ZGVjaW1hdGU9MSBpbnRlcmxhY2VkPTAgYmx1cmF5X2NvbXBhdD0wIGNvbnN0cmFpbmVkX2ludHJhPTAgYmZyYW1lcz0yIGJfcHlyYW1pZD0yIGJf
        YWRhcHQ9MCBiX2JpYXM9MCBkaXJlY3Q9MSB3ZWlnaHRiPTAgb3Blbl9nb3A9MCB3ZWlnaHRwPTAga2V5aW50PTYga2V5aW50X21pbj00IHNjZW5l
        Y3V0PTAgaW50cmFfcmVmcmVzaD0wIHJjPWNyZiBtYnRyZWU9MCBjcmY9NDAuMCBxY29tcD0wLjYwIHFwbWluPTAgcXBtYXg9NjkgcXBzdGVwPTQg
        aXBfcmF0aW89MS40MCBwYl9yYXRpbz0xLjMwIGFxPTAAgAAAAQZliIQA6DGADTLI+MGAo/hzi7LwBj1z59hITI6CMmL24v/iN3vuBNg61kHj7Dc2
        Uhvor3mHjrWg82bPQ30jOUOywICQRIGBQwBNnEQ4bF1CaGDni1FZDhuCdm2H0RQwhj8Ett40UBfAEdx1eblcD3/h4ZkVB9IYleumyu6HhM1ldLCb
        r31Ne0eemIu0wL6qx9Kq59YydWoGFM8raSD0eaMqq0++TKroBgAwDJz0K59ArYMPot/84bXjR+84bZdvPDfMVa6lH+z9/ed67n/34GHDnAAdD7HZ
        9i//PsWfYvxoGIEW8wLkcwLkWqB4kOqBYkF8exgDTP7v/97+DwCg8//6wfLDYHliAAADugkAACAAAGQAAAAAJwEAAZAAAAAXQZojAy88IWbIgEoz
        NjBhwJhohr+OF8kAAAArCQAAFgAAyAAAAAAnAQAAZAAAAA1BnkFAQs8UNCDYv/5IAAAAIQkAABkAASwAAAAAJwEAAGQAAAAQAZ5iQMWeoJBdm/TY
        039yQAAAACQJAAAVAAGQAAAAACcBAAEsAAAADEGaZTRKevBDm/kgkgAAACAJAAAPAAH0AAAAACcBAABkAAAABgGehECEWAAAABoJAADbAAJYAAAA
        ABcBAADIAAAA0mWIggCgxgB3x2MOPg5wv6Uib++4fJk8Jmb+dzldKnWtB5YzlDssO72HsliJ3jssfhAiQOFZAhs2jXqCI5n/6SqhooATCqEjtm/2
        58iDK5dRWQXwBHfeK/qDhwmSo/CXufcdCLXYQCffv/hHbPhic2MmzWbtonW7RgY2rUfIvU7Rm+lG7YMAwEnVKWPWa4aGln7ziOzjfOKTzUiJZI0n
        0Sat2fvPhhwPwDovr/rX4iUQh++E6I+wO8D7A7wFuygaAcAxwGWVAvwHKgP4NgWlBsB0oQAAAOYJAAAPAAK8AAAAACcBAAGQAAAABkGaIwMiwAAA
        ABoJAAAPAAMgAAAAACcBAABkAAAABkGeQUBCLAAAABoJAAAPAAOEAAAAACcBAABkAAAABgGeYkCkWAAAABoJAAASAAPoAAAAACcBAAEsAAAACUGa
        ZTRKdJ9aqAAAAB0JAAAPAARMAAAAACcBAABkAAAABgGehECEWAAAABoJAADcAASwAAAAABcBAADIAAAA02WIhAKDGAMpnZgDF/Qc4X9KRN/fcPky
        eEzF/PuMrpWtR8UTOUOyyos+ZLETnjssnOh3rxgAMKyBDZuGvUEqDXK8NcAJhVCR2zf7c+RvJPHaCYL4Ajp7xWqoUOEyVH4S9z7joRa7CAT79/8I
        7Z8MTmwybNrro3JrdowMbVqPkWanaGb6aq6BgYCR00pY9ZrhoaWfvOI7ON84pPNSIlkjSfRJq3Z+8+GHA/AOi+v/Wvx8Qh1NzBmPnlyfws/Cxjso
        GgHAMcBllQL8ByoD+DYFpQbAdKEAAADnCQAAFgAFFAAAAAAnAQABkAAAAA1BmiMDL16ueAtiGX6gAAAAIQkAAA8ABXgAAAAAJwEAAGQAAAAGQZ5B
        QEIsAAAAGgkAAA8ABdwAAAAAJwEAAGQAAAAGAZ5iQKRYAAAAGgkAABgABkAAAAAAJwEAASwAAAAPQZplNEp0nw1iuK1h0e/qAAAAIwkAAA8ABqQA
        AAAAJwEAAGQAAAAGAZ6EQIRYAAAAGgkAANYABwgAAAAAFwEAAMgAAADNZYiCAKDGAGvR2YAz8HOF/SkTf33D5MnhMxfz7jK6VndB5Zzod6+Y7D2S
        xE7x2WPwgRIDhWQIbNw16gdmFAJgEwqhI7Zv9ufJKxBjy6IrIL4AjvvFVVQUOEyVH4S9z7joRa7CAT79/8I7Z8MTmxk2azdtE63aMDG1aj5F6naM
        30o3bBgGA0dNKWPWa4aGln7ziOzjfOKTzUiJZI0n0Sat2fvPhhwItgDS6X1/1r8JRhCEOH/csP+5CfwHeB+D4C1VD1QDBhJH/8J+w2B9iAAAAOEJ
        AAARAAdsAAAAACcBAAGQAAAACEGaIwMn1KVQAAAAHAkAAA8AB9AAAAAAJwEAAGQAAAAGQZ5BQEIsAAAAGgkAAA8ACDQAAAAAJwEAAGQAAAAGAZ5i
        QKRYAAAAGgkAABkACJgAAAAAJwEAASwAAAAQQZplNEp0nw5ivKWM63V9QAAAACQJAAAPAAj8AAAAACcBAABkAAAABgGehECEWAAAABoJAAAFAAj8
        AAAAABcCAAAAAAAAEA==
        """, options: .ignoreUnknownCharacters)!

    /// Opened as a session's demuxer stands when it builds its plan: Matroska's Cues are loaded by a
    /// first seek, as the session's cue prewarm makes it.
    private static func open(_ data: Data) throws -> Demuxer {
        let demuxer = Demuxer()
        try demuxer.open(reader: DataIOReader(data: data), profile: .iFrameSideDemuxer)
        if demuxer.loadsIndexOnFirstSeek { _ = demuxer.seek(to: 0) }
        return demuxer
    }

    /// The keyframes the segment plan is built from (`Demuxer.indexedKeyframeEntries`), each with the
    /// packet `av_read_frame` hands over for it: the reference every route is checked against.
    private static func reference(_ data: Data) throws -> [(pts: Int64, pos: Int64, packet: Data)] {
        let demuxer = try open(data)
        defer { demuxer.close() }
        let video = demuxer.videoStreamIndex
        let entries = demuxer.indexedKeyframeEntries(streamIndex: video)
        var packets: [Int64: Data] = [:]
        while let packet = try demuxer.readPacket() {
            var owned: UnsafeMutablePointer<AVPacket>? = packet
            defer { av_packet_free(&owned) }
            guard packet.pointee.stream_index == video, packet.pointee.flags & AV_PKT_FLAG_KEY != 0,
                  let bytes = packet.pointee.data else { continue }
            let data = Data(bytes: bytes, count: Int(packet.pointee.size))
            packets[packet.pointee.dts] = data
            packets[packet.pointee.pts] = data
        }
        return try entries.map { (pts: $0.pts, pos: $0.pos, packet: try #require(packets[$0.pts])) }
    }

    /// A reader as a session builds one: the index resolved through the registry over `data`, the
    /// positions from the session demuxer's own index, and `data` again for the demuxer route.
    private static func reader(_ data: Data, session: Demuxer,
                               now: @escaping () -> Date = Date.init) -> IFrameKeyframeReader {
        let url = URL(string: "https://media.example.com/keyframes-\(UUID().uuidString).bin")!
        let positions = Dictionary(session.indexedKeyframeEntries(streamIndex: session.videoStreamIndex)
            .map { ($0.pts, $0.pos) }, uniquingKeysWith: { first, _ in first })
        return IFrameKeyframeReader(
            resolveIndex: {
                await HLSVideoEngine.iFrameKeyframeIndex(url: url, headers: [:], demuxer: session,
                                                         custom: DataIOReader(data: data))
            },
            position: { positions[$0] },
            open: { dem in try dem.open(reader: DataIOReader(data: data), profile: .iFrameSideDemuxer); return {} },
            now: now)
    }

    @Test("Matroska and MP4 keyframes come from the index, each the packet av_read_frame hands over",
          arguments: ["mkv", "mp4"])
    func indexedKeyframes(container: String) throws {
        let data = container == "mkv" ? Self.mkv : Self.mp4
        let reference = try Self.reference(data)
        try #require(reference.count >= 3)
        let session = try Self.open(data)
        defer { session.close() }
        let reader = Self.reader(data, session: session)
        defer { reader.interrupt(); reader.close() }
        for keyframe in reference.reversed() {
            #expect(reader.payload(startPts: keyframe.pts) == keyframe.packet, "\(container) at \(keyframe.pts)")
        }
        #expect(reader.readsFromIndex == true)
    }

    @Test("an FLV's keyframes are read by a demuxer of their own, as av_read_frame hands them over")
    func demuxedKeyframes() throws {
        let reference = try Self.reference(Self.flv)
        try #require(reference.count >= 3)
        let session = try Self.open(Self.flv)
        defer { session.close() }
        let reader = Self.reader(Self.flv, session: session)
        defer { reader.interrupt(); reader.close() }
        for keyframe in reference.reversed() {
            #expect(reader.payload(startPts: keyframe.pts) == keyframe.packet, "flv at \(keyframe.pts)")
        }
        #expect(reader.readsFromIndex == false)
    }

    /// mkvmerge writes `CueRelativePosition`, and so does ffmpeg; an older muxer names only the
    /// cluster. This fixture's one cluster holds all four keyframes, so the first block of the track
    /// would do for one of them only: the block is the one whose time is the cue's.
    @Test("a cue point without its relative position is found in its cluster by its time")
    func cueWithoutRelativePosition() throws {
        let reference = try Self.reference(Self.mkv)
        let source = IOReaderByteSource(DataIOReader(data: Self.mkv))
        var index = try MatroskaCueIndex.read(from: source, token: .forParserTests)
        let track = try #require(index.videoTracks.first?.number)
        #expect(index.keyframes(track: track).allSatisfy { $0.relativePosition != nil })
        index.keyframesByTrack[track] = index.keyframes(track: track).map {
            .init(ticks: $0.ticks, clusterPosition: $0.clusterPosition, relativePosition: nil)
        }
        for keyframe in reference {
            let read = index.readKeyframe(track: track, position: keyframe.pos, ticks: keyframe.pts, from: source)
            #expect(read.map { Data($0) } == keyframe.packet, "at \(keyframe.pts)")
        }
    }

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var time = Date(timeIntervalSince1970: 1_000)
        private var opened = 0
        private var resolved = 0
        var now: Date { lock.withLock { time } }
        func advance(_ seconds: TimeInterval) { lock.withLock { time += seconds } }
        func open() { lock.withLock { opened += 1 } }
        func resolve() { lock.withLock { resolved += 1 } }
        var opens: Int { lock.withLock { opened } }
        var resolutions: Int { lock.withLock { resolved } }
    }

    private static func demuxed(_ clock: Clock, open: @escaping (Demuxer) throws -> Void) -> IFrameKeyframeReader {
        IFrameKeyframeReader(resolveIndex: { .notIndexed("test") }, position: { _ in nil },
                             open: { dem in clock.open(); try open(dem); return {} }, now: { clock.now })
    }

    @Test("an index that cannot be read is a failure that cools down, never the demuxer")
    func unreadableIndexCoolsDown() {
        let clock = Clock()
        let reader = IFrameKeyframeReader(
            resolveIndex: { clock.resolve(); return .failed("a range dropped") }, position: { _ in 0 },
            open: { _ in clock.open(); return {} }, now: { clock.now })
        defer { reader.interrupt(); reader.close() }
        #expect(reader.payload(startPts: 0) == nil)
        #expect(reader.payload(startPts: 0) == nil)
        #expect(clock.resolutions == 1, "inside the cool-down the index is not asked again")
        clock.advance(6)
        #expect(reader.payload(startPts: 0) == nil)
        #expect(clock.resolutions == 2)
        #expect(clock.opens == 0)
        #expect(reader.readsFromIndex == nil)
    }

    @Test("a failed open is retried only after its cool-down, which grows with the second failure")
    func failedOpenIsRetriedAfterItsCoolDown() {
        let clock = Clock()
        let r = Self.demuxed(clock) { _ in throw NSError(domain: "test", code: 1) }
        defer { r.interrupt(); r.close() }
        #expect(r.payload(startPts: 0) == nil)
        #expect(r.payload(startPts: 100) == nil)
        #expect(clock.opens == 1, "five parallel requests must not each pay for an open")
        clock.advance(6)
        #expect(r.payload(startPts: 0) == nil)
        #expect(clock.opens == 2)
        clock.advance(6)
        #expect(r.payload(startPts: 0) == nil)
        #expect(clock.opens == 2, "the second failure in a row holds for 30 s")
        clock.advance(30)
        #expect(r.payload(startPts: 0) == nil)
        #expect(clock.opens == 3)
    }

    @Test("a failed read cools down, then reopens a fresh demuxer and recovers")
    func failedReadReopens() throws {
        let clock = Clock()
        let reference = try Self.reference(Self.flv)
        let first = try #require(reference.first)
        let r = Self.demuxed(clock) { dem in try dem.open(reader: DataIOReader(data: Self.flv), profile: .iFrameSideDemuxer) }
        defer { r.interrupt(); r.close() }
        #expect(r.payload(startPts: first.pts) != nil)
        // Far past the end: no keyframe to land on, which is what a dead connection looks like here.
        #expect(r.payload(startPts: Int64.max / 4) == nil)
        #expect(r.payload(startPts: first.pts) == nil, "inside the cool-down the source is left alone")
        #expect(clock.opens == 1)
        clock.advance(6)
        #expect(r.payload(startPts: first.pts) == first.packet)
        #expect(clock.opens == 2)
    }

    @Test("cleanup runs exactly once on close, opened or not")
    func cleanupRunsOnce() {
        final class Count: @unchecked Sendable { var n = 0 }
        let untouched = Count()
        let never = IFrameKeyframeReader(resolveIndex: { .notIndexed("test") }, position: { _ in nil },
                                         open: { _ in {} }, cleanup: { untouched.n += 1 })
        never.interrupt(); never.close(); never.close()
        #expect(untouched.n == 1)
    }

    @Test("after interrupt every call answers nil")
    func interruptEndsIt() throws {
        let reference = try Self.reference(Self.mp4)
        let session = try Self.open(Self.mp4)
        defer { session.close() }
        let r = Self.reader(Self.mp4, session: session)
        #expect(r.payload(startPts: reference[0].pts) != nil)
        r.interrupt()
        #expect(r.payload(startPts: reference[0].pts) == nil)
        r.close()
    }

    @Test("interrupt ends a wait for an index that has not answered", .timeLimit(.minutes(1)))
    func interruptEndsTheIndexWait() {
        let r = IFrameKeyframeReader(
            resolveIndex: { try? await Task.sleep(for: .seconds(30)); return .notIndexed("late") },
            position: { _ in nil }, open: { _ in {} })
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread { _ = r.payload(startPts: 0); done.signal() }
        Thread.sleep(forTimeInterval: 0.2)
        r.interrupt()
        #expect(done.wait(timeout: .now() + 10) == .success)
        r.close()
    }

    @Test("the I-frame side profile reads like the still extractor under its own log name")
    func profile() {
        let p = DemuxerOpenProfile.iFrameSideDemuxer
        #expect(p.readerLabel == "iframe")
        #expect(p.avioPrefetch == DemuxerOpenProfile.stillExtraction.avioPrefetch)
        #expect(p.probesize == DemuxerOpenProfile.stillExtraction.probesize)
        #expect(DemuxerOpenProfile.labelsWithoutCompositionRepair.contains("iframe"))
        #expect(DemuxerOpenProfile.labelsWithoutCompositionRepair.contains("extract"))
    }

    @Test("interrupt aborts an open that is still in flight", .timeLimit(.minutes(3)))
    func interruptAbortsAnOpenInFlight() {
        let parked = ProbeParkedReader(operation: .read)
        parked.mayReturn.open()
        let entered = DispatchSemaphore(value: 0)
        let r = IFrameKeyframeReader(resolveIndex: { .notIndexed("test") }, position: { _ in nil }, open: { dem in
            entered.signal()
            try dem.open(reader: parked, formatHint: "mp4", profile: .iFrameSideDemuxer)
            return {}
        })
        let done = DispatchSemaphore(value: 0)
        // A thread of its own: a loaded runner starves the global pool for seconds.
        Thread.detachNewThread { _ = r.payload(startPts: 0); done.signal() }
        entered.wait()
        Thread.sleep(forTimeInterval: 0.2)
        r.interrupt()
        let returned = done.wait(timeout: .now() + 120) == .success
        #expect(returned, "payload() was still inside the open 120 seconds after interrupt()")
        parked.release()
        if !returned { done.wait() }
        r.close()
    }
}
