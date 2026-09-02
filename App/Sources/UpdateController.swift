// Sparkle-backed updates. Replaces the hand-rolled GitHub API check so an
// update is download + install + relaunch in-app, not a browser trip.
//
// Privacy posture is unchanged: Sparkle makes no network call until the user
// either consents to automatic checks (Sparkle's one-time permission prompt,
// or the Settings toggle) or clicks "Check for Updates…". The feed is
// appcast.xml on the repo's main branch; updates are EdDSA-signed by
// release.sh (key in the login keychain, public key in Info.plist).

import AppKit
import Combine
import Sparkle

@MainActor
final class UpdateController {
    static let shared = UpdateController()

    private let controller: SPUStandardUpdaterController

    /// False when Info.plist carries no SUFeedURL (debug builds strip it). Sparkle
    /// would still start without a feed, show its permission prompt, and raise a
    /// raw "Update Error" on a manual check — so the missing key is the single
    /// switch that turns the whole updater off.
    let isAvailable: Bool

    private init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        isAvailable = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
        guard isAvailable else { return }
        migrateLegacyLaunchCheckPreference()
        controller.startUpdater()
    }

    func checkForUpdates() {
        guard isAvailable else { return }
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    /// Backed by Sparkle's own SUEnableAutomaticChecks user default.
    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    /// Sparkle flips the value itself when the user answers its one-time
    /// permission prompt, so the Settings toggle has to observe rather than
    /// poll — the prompt can be answered with the window already open and the
    /// app already frontmost, which no activation or appearance hook catches.
    /// Safe before startUpdater(): the updater exists from init and Sparkle
    /// documents the property as KVO compliant.
    var automaticallyChecksForUpdatesPublisher: AnyPublisher<Bool, Never> {
        controller.updater.publisher(for: \.automaticallyChecksForUpdates).eraseToAnyPublisher()
    }

    /// Pre-Sparkle releases stored a "check at launch" flag (present only if the
    /// user ever touched the toggle). Carry the stored decision over both ways:
    /// an opt-in enables Sparkle's automatic checks, and an explicit opt-out
    /// records "off" — either value suppresses Sparkle's one-time permission
    /// prompt, so a question the user already answered is never re-asked. Must
    /// run before startUpdater() so the first scheduled check respects it.
    private func migrateLegacyLaunchCheckPreference() {
        let defaults = UserDefaults.standard
        let legacyKey = "checkUpdatesAtLaunch"
        guard defaults.object(forKey: legacyKey) != nil else { return }
        controller.updater.automaticallyChecksForUpdates = defaults.bool(forKey: legacyKey)
        defaults.removeObject(forKey: legacyKey)
    }
}
