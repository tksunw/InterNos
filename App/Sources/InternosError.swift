// The app's own failure cases, shared by the recorder, the engine, the inserter
// and the controller. Each one maps to a distinct log line and recovery path in
// DictationController, so keep them specific rather than folding them together.

import Foundation

enum InternosError: Error, Equatable {
    case audioConverterUnavailable
    case analyzerFormatUnavailable
    case modelNotInstalled
    case secureInputActive
    case accessibilityNotGranted
    /// The app frontmost at insertion time is not the one that owned the cursor when
    /// recording stopped (or that app exited). Distinct from Secure Input/Accessibility
    /// failures so logs and handling don't conflate them.
    case insertionTargetChanged
    /// CGEvent construction for the synthetic ⌘V failed; nothing was posted.
    case pasteEventFailed
    /// "Scratch that" found the caret somewhere other than where the last
    /// insertion left it (another field or document in the same app). Nothing
    /// was deleted.
    case scratchTargetChanged
}
