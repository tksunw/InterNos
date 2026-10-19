// The smart-cleanup level: a setting (AppSettings, the Settings picker, the
// Shortcuts action) and a pipeline input (TranscriptPipeline, SmartCleanup).

import Foundation

enum CleanupMode: String, CaseIterable, Identifiable, Sendable {
    case off
    case light
    case polished
    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: "Off"
        case .light: "Light"
        case .polished: "Polished"
        }
    }

    /// Model cleanup is prompt-engineered and validated for English only; fed
    /// Spanish input under English instructions, the model translated the
    /// dictation outright (beta-5 field report). Other recognition languages
    /// take the deterministic path until per-language prompts are validated.
    func effective(forLocaleIdentifier identifier: String) -> CleanupMode {
        identifier.lowercased().hasPrefix("en") ? self : .off
    }
}
