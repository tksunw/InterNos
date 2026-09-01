// Sparkle-backed updates. Replaces the hand-rolled GitHub API check so an
// update is download + install + relaunch in-app, not a browser trip.
//
// Privacy posture is unchanged: Sparkle makes no network call until the user
// either consents to automatic checks (Sparkle's one-time permission prompt,
// or the Settings toggle) or clicks "Check for Updates…". The feed is
// appcast.xml on the repo's main branch; updates are EdDSA-signed by
// release.sh (key in the login keychain, public key in Info.plist).

import AppKit
import Sparkle

@MainActor
final class UpdateController {
    static let shared = UpdateController()

    private let controller: SPUStandardUpdaterController

    private init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        migrateLegacyLaunchCheckPreference()
        controller.startUpdater()
    }

    func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    /// Backed by Sparkle's own SUEnableAutomaticChecks user default.
    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
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
