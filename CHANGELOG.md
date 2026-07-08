# Changelog

All notable changes to Internos are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/).

## [1.0.8] - 2026-07-07

### Fixed
- Requesting Input Monitoring during onboarding now reliably registers Internos
  in the System Settings pane (previously the app could be impossible to grant:
  the request API alone sometimes created no entry to toggle).

### Changed
- Menu bar icon now uses the app's waveform-and-mic glyph when idle (and a
  slashed waveform when paused) instead of a generic microphone, so the menu
  bar presence is recognizably Internos. Recording, transcribing, and error
  states keep their existing symbols.

## [1.0.7] - 2026-07-07

### Added
- "About Internos" menu item showing the standard About panel (version, build,
  copyright).

## [1.0.6] - 2026-07-07

First open-source release: the repository is now public under the MIT
license, with a [privacy policy](PRIVACY.md) and a full correctness and
security review behind it.

### Added
- "Check for Updates…" menu item. Queries the GitHub latest-release API on
  demand and offers the release page when a newer version exists. User-initiated
  only — Internos still makes zero automatic network calls.
- Optional "Check for updates at launch" setting (default off). When enabled,
  one request to GitHub at startup, silent unless an update is available.

### Fixed
- Rapidly starting a new dictation while the previous one was still finalizing
  no longer leaves the menu bar icon reading idle and the voice-print indicator
  hidden during the new recording.
- Two dictations within 300 ms no longer overwrite the clipboard contents saved
  from before the first one.
- If the clipboard was empty before dictating, it is now cleared again after
  insertion instead of keeping the transcript.
- Failed microphone starts no longer leak the audio tap; a data race between
  the audio thread and stop() was removed.
- Update check hardening: version comparison is component-wise, and only
  https release URLs are ever opened.

## [1.0.5] - 2026-07-07

### Added
- Spoken hashtags: "hashtag yard" is inserted as `#yard`.
- Spoken emoji with an explicit prefix: "emoji thumbs up" is inserted as 👍.
  The `emoji` keyword is required so literal speech ("she sent me a smiley
  face") is never converted. ~28 common names supported.
- Explicit spoken symbols: "at sign" → `@`, "dollar sign" → `$`,
  "percent sign" → `%`.
- Test target (`swift test`) covering the substitution rules.

## [1.0.4] - 2026-07-02

### Added
- Drag-to-Applications DMG installer, notarized and stapled.

### Fixed
- Debug builds now use a distinct bundle ID (`net.timkennedy.internos.debug`)
  so development copies never steal TCC permission grants from an installed
  release copy.

## [1.0.3] - 2026-07-02

### Added
- First notarized, distributable build (Developer ID signed, stapled).

## [1.0.2] - 2026-07-02

### Changed
- Recording indicator upgraded to a live voice-print visualization.

### Fixed
- Transcript content is no longer written to the unified log (lengths only).

## [1.0.1] - 2026-07-02

### Fixed
- Microphone access broken under the hardened runtime.

## [1.0.0] - 2026-07-02

Initial release.

### Added
- Hold-to-dictate (push-to-talk) and toggle activation modes with a
  configurable global hotkey (default: Right Option).
- Fully on-device transcription via Apple's `SpeechAnalyzer`/`SpeechTranscriber`
  (macOS 26+, Apple Silicon, en-US).
- Text insertion at the cursor via clipboard swap with clipboard restore.
- Secure Input detection: refuses to inject into password fields and preserves
  the transcript on the clipboard instead.
- Menu bar shell, settings (hotkey, activation mode, microphone, sounds),
  permission onboarding, and speech model download UI.

[1.0.8]: https://github.com/tksunw/InterNos/compare/v1.0.7...v1.0.8
[1.0.7]: https://github.com/tksunw/InterNos/compare/v1.0.6...v1.0.7
[1.0.6]: https://github.com/tksunw/InterNos/compare/v1.0.5...v1.0.6
[1.0.5]: https://github.com/tksunw/InterNos/compare/v1.0.4...v1.0.5
[1.0.4]: https://github.com/tksunw/InterNos/compare/v1.0.3...v1.0.4
[1.0.3]: https://github.com/tksunw/InterNos/compare/v1.0.2...v1.0.3
[1.0.2]: https://github.com/tksunw/InterNos/compare/v1.0.1...v1.0.2
[1.0.1]: https://github.com/tksunw/InterNos/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/tksunw/InterNos/releases/tag/v1.0.0
