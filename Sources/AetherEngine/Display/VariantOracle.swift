import Foundation
import AVFoundation
import os

/// Asks AVFoundation, in its own terms, which HDR formats it will put on this display: offer it an HLS master whose
/// variants differ only in codec and video range, and see which media playlist it asks for first (the variant it
/// starts on). The variant filter is the one that answers -11868 to a Dolby Vision P5 master on a panel without
/// Dolby Vision, so this is the capability question the engine routes on, asked the way it is answered.
///
/// Nothing is decoded and nothing is shown: playlists are served from memory through a custom-scheme resource
/// loader and every segment request is refused, and the run ends at the first media playlist request (plus a short
/// grace for whatever follows it) or at `timeout`.
@MainActor
final class VariantOracle {

    /// Why a run stopped watching.
    enum Ending: String, Sendable {
        /// A variant was picked and the grace after it ran out.
        case picked
        /// The item failed.
        case failed
        /// Nothing settled within the timeout.
        case timedOut
        /// The task running it was cancelled (a session starting).
        case cancelled
    }

    struct Result: Sendable {
        let ladder: DisplaySignals.Ladder
        let attachment: String
        /// Every request in arrival order, by file name.
        let requests: [String]
        let firstPick: DisplaySignals.Candidate?
        let status: String
        let errorDomain: String?
        let errorCode: Int?
        let elapsedMs: Int
        let ended: Ending

        var failed: Bool { status == "failed" }
        var verdict: DisplaySignals.Verdict {
            DisplaySignals.verdict(ladder, firstPick: firstPick, failed: failed)
        }
    }

    nonisolated static let scheme = "aedisplayprobe"

    /// `attach` puts the player on a layer the caller provides for the run (a display-bound player may be
    /// filtered differently from a bare one), nil runs it bare.
    static func run(_ ladder: DisplaySignals.Ladder,
                    attachment: String,
                    attach: ((AVPlayer) -> (() -> Void))? = nil,
                    timeout: Duration = .seconds(6),
                    grace: Duration = .milliseconds(400)) async -> Result {
        let clock = ContinuousClock()
        let started = clock.now
        let loader = Loader(ladder: ladder)
        let runID = UUID().uuidString.prefix(8)
        let url = URL(string: "\(scheme)://oracle/\(runID)/master.m3u8")!
        let asset = AVURLAsset(url: url)
        asset.resourceLoader.setDelegate(loader, queue: loader.queue)
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 1
        let player = AVPlayer()
        player.isMuted = true
        player.automaticallyWaitsToMinimizeStalling = false
        #if os(iOS) || os(tvOS)
        player.allowsExternalPlayback = false
        player.preventsDisplaySleepDuringVideoPlayback = false
        #endif
        let detach = attach?(player)
        player.replaceCurrentItem(with: item)

        var pickedAt: ContinuousClock.Instant?
        let ended: Ending
        while true {
            // A cancelled sleep returns at once, so without this a cancelled run would spin until `timeout`.
            if Task.isCancelled { ended = .cancelled; break }
            if pickedAt == nil, loader.firstPick != nil { pickedAt = clock.now }
            if let pickedAt, clock.now - pickedAt >= grace { ended = .picked; break }
            if item.status == .failed { ended = .failed; break }
            if clock.now - started >= timeout { ended = .timedOut; break }
            try? await Task.sleep(for: .milliseconds(20))
        }

        let status: String
        switch item.status {
        case .unknown: status = "unknown"
        case .readyToPlay: status = "ready"
        case .failed: status = "failed"
        @unknown default: status = "?"
        }
        let error = item.error as NSError?
        player.replaceCurrentItem(with: nil)
        detach?()
        asset.resourceLoader.setDelegate(nil, queue: nil)
        let elapsed = clock.now - started
        return Result(ladder: ladder, attachment: attachment, requests: loader.requests,
                      firstPick: loader.firstPick, status: status,
                      errorDomain: error?.domain, errorCode: error?.code,
                      elapsedMs: Int(elapsed.components.seconds * 1000
                                     + elapsed.components.attoseconds / 1_000_000_000_000_000),
                      ended: ended)
    }

    /// Serves the ladder's playlists and refuses everything else, recording each request.
    final class Loader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
        let queue = DispatchQueue(label: "aetherengine.display-signals.oracle")
        private let ladder: DisplaySignals.Ladder
        private let state = OSAllocatedUnfairLock(initialState: (requests: [String](), firstPick: DisplaySignals.Candidate?.none))

        init(ladder: DisplaySignals.Ladder) {
            self.ladder = ladder
        }

        var requests: [String] { state.withLock { $0.requests } }
        var firstPick: DisplaySignals.Candidate? { state.withLock { $0.firstPick } }

        func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                            shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
            guard let url = loadingRequest.request.url, url.scheme == VariantOracle.scheme else { return false }
            let requested = DisplaySignals.requested(path: url.path)
            let name = (url.path as NSString).lastPathComponent
            state.withLock { current in
                current.requests.append(name)
                if case .mediaPlaylist(let variant) = requested, current.firstPick == nil { current.firstPick = variant }
            }
            switch requested {
            case .master:
                respond(loadingRequest, with: DisplaySignals.masterPlaylist(ladder))
            case .mediaPlaylist(let variant):
                respond(loadingRequest, with: DisplaySignals.mediaPlaylist(variant))
            case .media, .unknown:
                loadingRequest.finishLoading(with: NSError(domain: NSURLErrorDomain, code: NSURLErrorResourceUnavailable))
            }
            return true
        }

        private func respond(_ request: AVAssetResourceLoadingRequest, with playlist: String) {
            let data = Data(playlist.utf8)
            if let info = request.contentInformationRequest {
                info.contentType = "public.m3u-playlist"
                info.contentLength = Int64(data.count)
                info.isByteRangeAccessSupported = false
            }
            request.dataRequest?.respond(with: data)
            request.finishLoading()
        }
    }
}
