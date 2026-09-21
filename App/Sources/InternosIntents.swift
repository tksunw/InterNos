// App Intents: actions for the Shortcuts app. Each intent calls the same
// controller path as its hotkey or menu equivalent, and none returns transcript
// text: the volatile store stays memory-only and never leaves the app.
//
// ponytail: no AppShortcutsProvider. On macOS 27 it put nothing in Spotlight, and
// Siri phrases are not wanted for a dictation utility. Add one if that changes.
//
// The system runs these in-process (launching Internos first if needed). They are
// discovered through Contents/Resources/Metadata.appintents, which make-app.sh
// generates; SwiftPM does not produce it on its own.

import AppIntents

enum IntentFailure: Error, CustomLocalizedStringResourceConvertible {
    case notReady
    case nothingToPaste
    case polishedUnavailable

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notReady: "Internos can't dictate right now. It may be paused, still starting, or missing a permission."
        case .nothingToPaste: "There is no dictation to paste yet."
        case .polishedUnavailable: "Polished cleanup needs Apple Intelligence turned on in System Settings."
        }
    }
}

struct ToggleDictationIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Dictation"
    static let description = IntentDescription(
        "Starts dictating, or stops and inserts the text at the cursor. Works in either activation mode.")

    @MainActor
    func perform() async throws -> some IntentResult {
        guard DictationController.current?.toggleDictation() == true else { throw IntentFailure.notReady }
        return .result()
    }
}

struct PasteLastDictationIntent: AppIntent {
    static let title: LocalizedStringResource = "Paste Last Dictation"
    static let description = IntentDescription(
        "Inserts the most recent dictation again, into the app you were last using.")

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let controller = DictationController.current else { throw IntentFailure.notReady }
        guard controller.volatileStore.current != nil else { throw IntentFailure.nothingToPaste }
        controller.pasteLastDictation()
        return .result()
    }
}

struct SetCleanupLevelIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Cleanup Level"
    static let description = IntentDescription("Chooses how much Internos tidies dictated text.")

    @Parameter(title: "Level")
    var level: CleanupMode

    @MainActor
    func perform() async throws -> some IntentResult {
        // Same rule as the Settings picker: Polished is not selectable without the model.
        if level == .polished, !CleanupAvailability.isAvailable { throw IntentFailure.polishedUnavailable }
        AppSettings.shared.cleanupMode = level
        return .result()
    }
}

extension CleanupMode: AppEnum {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Cleanup Level"
    static let caseDisplayRepresentations: [CleanupMode: DisplayRepresentation] = [
        .off: "Off", .light: "Light", .polished: "Polished",
    ]
}
