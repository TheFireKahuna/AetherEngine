import AVFoundation
import AVKit
import MediaAccessibility
import SwiftUI
import UIKit

// A `subs` arm: AVPlayer on Scripts/build_subs.sh's stream (regular, SDH and forced WebVTT renditions whose
// every cue names itself), shown through a plain AVPlayerLayer, to settle what the engine's subtitle model
// would rest on: AVKit selects a rendition by itself, and `AVPlayerItemLegibleOutput.suppressesPlayerRendering`
// keeps AVKit from drawing it while its cues still arrive. `case=`:
//
// - `auto`: the control, nothing suppressed. AVFoundation selects by itself for 8 s (expect the forced rendition
//   when the viewer has subtitles off: "FORCED #0" at the top, 1.5 to 5.5 s), then the regular one is selected.
// - `sup`: the same with a suppressing output attached before playback: nothing may be drawn, while the log shows
//   the output receiving FORCED and REGULAR cues.
// - `trap`: regular drawn by AVKit; at 10.5 s, mid-line ("REGULAR #3", 9.2 to 11.8 s), suppression is switched on as
//   it is: does #3 stay frozen on screen? At 16 s the clear (deselect, reselect) is applied: does it go?
// - `fix`: as `trap`, but at 10.5 s the line is cleared first (deselect, suppress, reselect): nothing may stay. At
//   16 s suppression is lifted: AVKit draws again from the next line.
// - `pip`: suppressed from the start, regular selected; the playback audio session, as the engine sets it, and a PiP
//   controller made at once, whose `isPictureInPicturePossible` is followed; at 4 s (or once PiP becomes possible,
//   within 8 s) Picture in Picture is started, and on its start
//   suppression is lifted (the window should show REGULAR lines); at 14 s it is stopped, and on its stop the line is
//   cleared and suppression armed again: the full screen must show nothing, and no line may freeze.
// - `sdh`: the viewer's caption display type set to Always On ("Closed Captions + SDH") for the arm, restored
//   after it; AVFoundation selects by itself: expect "[SDH]" lines, nothing suppressed.
@MainActor
final class SubtitleProbeSession: NSObject, AVPlayerItemLegibleOutputPushDelegate, AVPictureInPictureControllerDelegate {
    let view = SubtitleProbeView()
    private let player = AVPlayer()
    private let url: URL
    private let probeCase: String
    private let log: @Sendable (String) -> Void
    private var item: AVPlayerItem?
    private var group: AVMediaSelectionGroup?
    private var output: AVPlayerItemLegibleOutput?
    private var pip: AVPictureInPictureController?
    private var lastCue = ""
    private var pipPossible: NSKeyValueObservation?

    init(url: URL, params: [String: String], log: @escaping @Sendable (String) -> Void) {
        self.url = url
        probeCase = params["case"] ?? "auto"
        self.log = log
        super.init()
        view.playerLayer.player = player
    }

    func run() async {
        let savedDisplayType = MACaptionAppearanceGetDisplayType(.user)
        if probeCase == "sdh" {
            MACaptionAppearanceSetDisplayType(.user, .alwaysOn)
            log("subs: caption display type set to alwaysOn for the arm (was \(savedDisplayType.rawValue))")
        }
        defer {
            if probeCase == "sdh" {
                MACaptionAppearanceSetDisplayType(.user, savedDisplayType)
                log("subs: caption display type restored to \(savedDisplayType.rawValue)")
            }
            player.pause()
            player.replaceCurrentItem(with: nil)
        }
        log("subs: case=\(probeCase) displayType=\(MACaptionAppearanceGetDisplayType(.user).rawValue) "
            + "preferred=\(preferredCharacteristics())")
        let asset = AVURLAsset(url: url)
        do {
            group = try await asset.loadMediaSelectionGroup(for: .legible)
        } catch {
            log("subs: legible group failed to load: \(error)")
            return
        }
        for option in group?.options ?? [] {
            log("subs: option \(option.displayName) lang=\(option.extendedLanguageTag ?? "-") forcedOnly="
                + "\(option.hasMediaCharacteristic(.containsOnlyForcedSubtitles)) sdh="
                + "\(option.hasMediaCharacteristic(.transcribesSpokenDialogForAccessibility))")
        }
        let item = AVPlayerItem(asset: asset)
        self.item = item
        if ["sup", "trap", "fix", "pip"].contains(probeCase) {
            let output = AVPlayerItemLegibleOutput()
            output.suppressesPlayerRendering = probeCase == "sup" || probeCase == "pip"
            output.advanceIntervalForDelegateInvocation = 0
            output.setDelegate(self, queue: .main)
            item.add(output)
            self.output = output
            log("subs: legible output attached, suppressing=\(output.suppressesPlayerRendering)")
        }
        if probeCase == "pip" {
            // PiP is possible only for a player in the playback category, as the engine configures it.
            do {
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
                try AVAudioSession.sharedInstance().setActive(true)
                log("subs: audio session playback / moviePlayback")
            } catch {
                log("subs: audio session failed: \(error)")
            }
            makePictureInPictureController()
        }
        player.replaceCurrentItem(with: item)
        player.play()

        switch probeCase {
        case "auto", "sup":
            await watch(until: 8)
            select(named: "English")
            await watch(until: 16)
        case "trap":
            select(named: "English")
            await watch(until: 10.5)
            output?.suppressesPlayerRendering = true
            log("subs: suppression switched on mid-line, nothing cleared (REGULAR #3 is up until 11.8 s)")
            await watch(until: 16)
            await clear(then: { self.log("subs: the clear, at 16 s") })
            await watch(until: 22)
        case "fix":
            select(named: "English")
            await watch(until: 10.5)
            await clear(then: {
                self.output?.suppressesPlayerRendering = true
                self.log("subs: line cleared, then suppression on")
            })
            await watch(until: 16)
            output?.suppressesPlayerRendering = false
            log("subs: suppression lifted at 16 s; AVKit should draw from REGULAR #6 (18.2 s)")
            await watch(until: 24)
        case "pip":
            select(named: "English")
            await watch(until: 4)
            await startPictureInPicture()
            await watch(until: 14)
            stopPictureInPicture()
            await watch(until: 24)
        case "sdh":
            await watch(until: 14)
        default:
            log("subs: unknown case=\(probeCase)")
        }
        log("subs: done; last cue the output received: \(lastCue.isEmpty ? "none" : lastCue)")
    }

    // MARK: - Steps

    private func select(named name: String) {
        guard let item, let group, let option = group.options.first(where: { $0.displayName == name }) else {
            log("subs: no option named \(name)")
            return
        }
        item.select(option, in: group)
        log("subs: selected \(name)")
    }

    /// The clear the engine would use around a suppression change: deselect, one beat, the change, reselect.
    private func clear(then change: @MainActor () -> Void) async {
        guard let item, let group else { return }
        let selected = item.currentMediaSelection.selectedMediaOption(in: group)
        item.select(nil, in: group)
        try? await Task.sleep(nanoseconds: 100_000_000)
        change()
        item.select(selected, in: group)
        log("subs: cleared and reselected \(selected?.displayName ?? "nothing")")
    }

    /// Logs the selection once a second until the item's time reaches `seconds`.
    private func watch(until seconds: Double) async {
        var lastLogged = -1
        while player.currentTime().seconds < seconds {
            let now = player.currentTime().seconds
            if Int(now) != lastLogged, let item, let group {
                lastLogged = Int(now)
                let selected = item.currentMediaSelection.selectedMediaOption(in: group)?.displayName ?? "none"
                log(String(format: "subs: t=%.1f selected=%@ suppressing=%@ pip=%@", now, selected,
                           output.map { "\($0.suppressesPlayerRendering)" } ?? "no output",
                           "\(pip?.isPictureInPictureActive ?? false)"))
            }
            if item?.status == .failed {
                log("subs: item failed: \(item?.error.map { "\($0)" } ?? "?")")
                return
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    private func preferredCharacteristics() -> String {
        let values = MACaptionAppearanceCopyPreferredCaptioningMediaCharacteristics(.user).takeRetainedValue()
        return (values as? [String] ?? []).joined(separator: ",")
    }

    // MARK: - Picture in Picture

    private func makePictureInPictureController() {
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            log("subs: Picture in Picture is not supported here")
            return
        }
        let controller = AVPictureInPictureController(contentSource: .init(playerLayer: view.playerLayer))
        controller.delegate = self
        pip = controller
        let log = log
        pipPossible = controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { pip, _ in
            log("subs: PiP possible=\(pip.isPictureInPicturePossible)")
        }
    }

    /// Starts PiP once it is possible, waiting up to 8 s for that.
    private func startPictureInPicture() async {
        guard let pip else { return }
        let deadline = Date().addingTimeInterval(8)
        while !pip.isPictureInPicturePossible, Date() < deadline {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        log("subs: starting PiP (possible=\(pip.isPictureInPicturePossible))")
        pip.startPictureInPicture()
    }

    private func stopPictureInPicture() {
        guard let pip, pip.isPictureInPictureActive else {
            log("subs: PiP was not active at 14 s")
            return
        }
        pip.stopPictureInPicture()
    }

    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        MainActor.assumeIsolated {
            output?.suppressesPlayerRendering = false
            log("subs: PiP started; suppression lifted")
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        MainActor.assumeIsolated {
            log("subs: PiP stopped")
            Task { @MainActor in
                await self.clear(then: {
                    self.output?.suppressesPlayerRendering = true
                    self.log("subs: line cleared, suppression armed again")
                })
            }
        }
    }

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                failedToStartPictureInPictureWithError error: any Error) {
        MainActor.assumeIsolated { log("subs: PiP failed to start: \(error)") }
    }

    // MARK: - Legible output

    nonisolated func legibleOutput(_ output: AVPlayerItemLegibleOutput,
                                   didOutputAttributedStrings strings: [NSAttributedString],
                                   nativeSampleBuffers nativeSamples: [Any], forItemTime itemTime: CMTime) {
        let text = strings.map(\.string).joined(separator: " | ")
        MainActor.assumeIsolated {
            guard text != lastCue else { return }
            lastCue = text
            log(String(format: "subs: output received at %.2f: %@", itemTime.seconds, text.isEmpty ? "(clear)" : text))
        }
    }
}

final class SubtitleProbeView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

struct SubtitleProbeRepresentable: UIViewRepresentable {
    let session: SubtitleProbeSession
    func makeUIView(context: Context) -> SubtitleProbeView { session.view }
    func updateUIView(_ view: SubtitleProbeView, context: Context) {}
}
