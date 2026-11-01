// Diagnostics for field reports. All app logging goes through here.
//
// Why not NSLog: on macOS 27 NSLog reaches stderr but no longer lands in the
// unified log store (verified 2026-10-31 with a probe binary: the NSLog line
// was absent from `log show`, os.Logger lines from the same process were
// present). A user's `log show` therefore saw nothing from a day of dictation.
//
// Rule (PRIVACY.md): never pass transcript, selection or clipboard content.
// Messages carry modes, elapsed times, character counts and error types only,
// which is why every message is logged `.public`; a redacted log is useless
// for the reports this exists for.
//
// Reading it:
//   log show --predicate 'subsystem BEGINSWITH "net.timkennedy.internos"' --last 1h
// The inner binary run from a terminal also echoes every line to stderr.

import Foundation
import os

enum Log {
    /// Release and debug builds have different bundle identifiers, so each has
    /// its own subsystem. One category: the messages name their own topic.
    static let subsystem = Bundle.main.bundleIdentifier ?? "net.timkennedy.internos"
    private static let logger = Logger(subsystem: subsystem, category: "app")

    /// Normal operation: state changes and outcomes, including designed fallbacks.
    static func info(_ message: String) {
        logger.notice("\(message, privacy: .public)")
        echo(message)
    }

    /// Something failed or an insertion was refused.
    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        echo(message)
    }

    private static func echo(_ message: String) {
        guard isatty(STDERR_FILENO) != 0 else { return }
        FileHandle.standardError.write(Data("Internos: \(message)\n".utf8))
    }
}
