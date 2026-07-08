// Manual "Check for Updates…" against the GitHub latest-release API.
// Deliberately user-initiated only: the app's premise is zero network calls,
// so nothing here runs automatically — no scheduled checks, no phoning home.
// ponytail: no Sparkle. Add it if release cadence ever makes manual checks annoying.

import AppKit

@MainActor
enum UpdateChecker {
    private static let latestReleaseAPI = URL(string: "https://api.github.com/repos/tksunw/InterNos/releases/latest")!

    /// quiet: only surface an available update — no "up to date" or error alerts.
    /// Used by the opt-in launch check so a healthy start stays silent.
    static func check(quiet: Bool = false) {
        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: latestReleaseAPI)
                struct Release: Decodable {
                    let tag_name: String
                    let html_url: String
                }
                let release = try JSONDecoder().decode(Release.self, from: data)
                let latest = release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name
                let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
                if isNewer(latest, than: current) {
                    // Only ever open https links from the API response.
                    let page = URL(string: release.html_url).flatMap { $0.scheme == "https" ? $0 : nil }
                    show(title: "Internos \(latest) is available",
                         text: "You have \(current). Download the new version from GitHub?",
                         downloadURL: page)
                } else if !quiet {
                    show(title: "You're up to date", text: "Internos \(current) is the latest version.")
                }
            } catch {
                if !quiet {
                    show(title: "Couldn't check for updates",
                         text: "GitHub wasn't reachable. Try again later.\n(\(error.localizedDescription))")
                }
            }
        }
    }

    /// Component-wise compare so "1.0" == "1.0.0" (string .numeric would call it older).
    static func isNewer(_ latest: String, than current: String) -> Bool {
        let l = latest.split(separator: ".").map { Int($0) ?? 0 }
        let c = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(l.count, c.count) {
            let a = i < l.count ? l[i] : 0
            let b = i < c.count ? c[i] : 0
            if a != b { return a > b }
        }
        return false
    }

    private static func show(title: String, text: String, downloadURL: URL? = nil) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        if let downloadURL {
            alert.addButton(withTitle: "Download")
            alert.addButton(withTitle: "Later")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(downloadURL)
            }
        } else {
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }
}
