import Foundation

/// The display's proof that an HDR criteria write drives it into HDR, kept between launches.
///
/// The proof is earned only around a dynamic-range transition (`currentEDRHeadroom` rising above 1.0), so a
/// process that has not watched one cannot prove the panel itself, and an unproven panel's master waits for
/// the switch to end (#667) before AVPlayer is handed it. Stored, a launch starts from what the display
/// already showed.
///
/// A stored proof stands for the output configuration it was earned under: whether the user allows display
/// mode switches (`isDisplayCriteriaMatchingEnabled`) and whether AVFoundation calls the display
/// HDR-eligible. A launch under a different configuration reads no proof. The rest of what tvOS lets a user
/// change (range matching off, frame-rate matching kept) reports through neither, so a stale proof is
/// possible there; it costs one in-place media fallback, and the refusal that fallback answers forgets the
/// proof (`DisplayCriteriaController.forgetPanelProof`).
enum PanelProof {
    /// The output configuration a proof was earned under.
    struct Configuration: Equatable, Sendable, Codable {
        var matchingEnabled: Bool
        var eligibleForHDR: Bool
    }

    /// Where the proof is kept. Injected so tests never touch the process's defaults.
    struct Store: Sendable {
        let load: @Sendable () -> Configuration?
        let save: @Sendable (Configuration?) -> Void

        static let key = "AetherEngine.PanelProof.v1"

        static let userDefaults = Store(
            load: {
                guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
                return try? JSONDecoder().decode(Configuration.self, from: data)
            },
            save: { configuration in
                if let configuration, let data = try? JSONEncoder().encode(configuration) {
                    UserDefaults.standard.set(data, forKey: key)
                } else {
                    UserDefaults.standard.removeObject(forKey: key)
                }
            })

        /// A store that keeps nothing between instances.
        static func memory() -> Store {
            let box = MemoryBox()
            return Store(load: { box.value }, save: { box.value = $0 })
        }

        private final class MemoryBox: @unchecked Sendable {
            private let lock = NSLock()
            private var stored: Configuration?
            var value: Configuration? {
                get { lock.withLock { stored } }
                set { lock.withLock { stored = newValue } }
            }
        }
    }

    /// Whether a stored proof stands for the configuration the display reports now.
    static func stands(stored: Configuration?, current: Configuration) -> Bool {
        stored == current
    }
}
