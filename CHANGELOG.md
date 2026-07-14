# Changelog

All notable changes to Internos are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- Command mode: select text anywhere, hold the command key (default Right
  Command, configurable), speak an instruction, release — the selection is
  rewritten in place by the on-device Apple Intelligence model. The selection
  is read only at the moment of invocation; any failure leaves it untouched,
  and the original text is recoverable via Copy Last Raw Dictation.
- Live transcript preview: the floating indicator shows your words as they're
  recognized, while you're still speaking.
- "Scratch that": say it as its own utterance to delete the previous dictation
  or command-mode rewrite (one level, same app only).
- Recognition languages: Settings → Language lists every locale the on-device
  recognizer supports; switching may trigger a one-time system model download.
  Spoken commands remain English for now.

### Changed
- Insertion now prefers the Accessibility API, placing text directly into the
  focused field. On that path the transcript never touches the clipboard; the
  clipboard swap remains only as a fallback for apps without Accessibility
  text support.

## [1.2.0] - 2026-07-14

### Added
- Personal dictionary: configurable spoken-phrase replacements ("cube control" →
  `kubectl`), matched whole-word and case-insensitively, output typed exactly as
  configured. Managed in Settings → Customizations with search, enable/disable,
  and JSON import/export (Merge or Replace).
- Voice-triggered snippets: "snippet <name>" inserts saved text verbatim
  (multiline and Unicode safe, 16 KB limit, static text only).
- Structured voice commands: "new line", "new paragraph", "bullet point",
  "numbered item" (with automatic numbering and paragraph resets), "open/close
  quote", "open/close parenthesis", and a "literal" escape that keeps the next
  command as plain words.
- Optional on-device smart cleanup (Settings → Processing; off by default):
  Light removes filler, repetitions, false starts, and applies self-corrections;
  Polished also smooths fragments into prose. Runs entirely on-device via Apple
  Intelligence (Foundation Models), bounded by a two-second deadline and output
  validation, and always falls back to the deterministic transcript. Requires an
  Apple-Intelligence-eligible Mac.
- Last-dictation recovery in the menu bar: Copy, Paste (into the app you were
  just using, with the usual Secure Input and focus checks), Copy Raw (when
  cleanup changed the text), and Clear. Held in memory only; quitting clears it.
- Settings window rebuilt as a resizable General / Processing / Customizations
  layout, including a spoken-command reference.

## [1.1.0] - 2026-07-14

### Fixed
- Back-to-back dictations now always insert in recording order, even when a later
  utterance finishes transcribing first, and an earlier utterance's completion can
  no longer flicker the menu-bar icon, hide the indicator, or play sounds over a
  newer recording.
- Clipboard restoration no longer overwrites content you copied right after
  dictating: the original clipboard is put back only if the pasteboard still holds
  the injected transcript.
- The transcript is pasted only into the app that was frontmost when you released
  the hotkey. If you switch apps during finalization (or that app quits), Internos
  refuses to paste, keeps the transcript on the clipboard, and shows the error state.
- Pause now cancels all in-flight work: nothing is inserted after you pause, and a
  transcription finishing while paused can no longer flip the icon back to idle. A
  transcript that had already completed is preserved on the clipboard, not injected.
- Releasing the dictation key while its left-side twin is held down (e.g. Right
  Option released while Left Option is held) now correctly stops recording, and a
  briefly disabled event tap can no longer leave a recording stuck on.
- Setup failures (model install, event tap) now stay visible as a persistent error
  instead of quietly reverting to the idle icon after a few seconds.
- The setup window no longer reports the speech model as installed until macOS
  actually reports it installed, shows download errors in the window itself, and
  ignores repeated Download clicks while an attempt is running.
- A failed model download no longer leaves its progress timer running forever.
- A synthetic paste that can't be constructed is now reported as an error (with the
  transcript preserved on the clipboard) instead of being silently reported as
  success.

### Changed
- The injected transcript is now tagged with the standard transient/concealed
  pasteboard marker types so well-behaved clipboard managers skip it.
- README and privacy policy now describe the clipboard-swap insertion accurately:
  the transcript briefly passes through the general pasteboard, where Universal
  Clipboard or clipboard managers may observe it. Claims about Internos's own
  network behavior are unchanged (still zero calls in the dictation path).

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

[1.2.0]: https://github.com/tksunw/InterNos/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/tksunw/InterNos/compare/v1.0.8...v1.1.0
[1.0.8]: https://github.com/tksunw/InterNos/compare/v1.0.7...v1.0.8
[1.0.7]: https://github.com/tksunw/InterNos/compare/v1.0.6...v1.0.7
[1.0.6]: https://github.com/tksunw/InterNos/compare/v1.0.5...v1.0.6
[1.0.5]: https://github.com/tksunw/InterNos/compare/v1.0.4...v1.0.5
[1.0.4]: https://github.com/tksunw/InterNos/compare/v1.0.3...v1.0.4
[1.0.3]: https://github.com/tksunw/InterNos/compare/v1.0.2...v1.0.3
[1.0.2]: https://github.com/tksunw/InterNos/compare/v1.0.1...v1.0.2
[1.0.1]: https://github.com/tksunw/InterNos/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/tksunw/InterNos/releases/tag/v1.0.0
