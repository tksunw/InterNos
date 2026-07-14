# Internos

**Dictation that stays between us.**

Internos is a macOS menu bar utility for fully on-device voice-to-text: hold a hotkey, speak, release, and the transcription appears at your cursor in whatever app you're using. All speech processing runs on your Mac using Apple's native Speech framework. Internos makes zero network calls in the transcription path — your audio is never transmitted anywhere. Insertion works through a brief clipboard swap, so macOS clipboard services (Universal Clipboard, clipboard managers) can momentarily see the transcript, like any text you copy; see [PRIVACY.md](PRIVACY.md).

## Why

Tools like Wispr Flow are excellent, but they send your voice to cloud servers. Internos exists for people who want the same workflow without the hot mic phoning home: engineers under NDA, healthcare and legal folks, or anyone who reads privacy policies. The transcript of your passwords-adjacent muttering belongs to you.

## Requirements

- **macOS 26 (Tahoe) or later** — the `SpeechAnalyzer`/`SpeechTranscriber` APIs don't exist earlier
- **Apple Silicon**
- English (US) in v1

## Install

1. Download `Internos-x.y.z.dmg` from [Releases](../../releases) and open it. Drag **Internos** onto the **Applications** folder in the installer window.
2. Launch it from Applications. The setup window walks you through the three permissions it needs:
   - **Microphone** — capturing your voice while the hotkey is held
   - **Input Monitoring** — detecting the hotkey anywhere in macOS
   - **Accessibility** — inserting text at your cursor
3. Let it download the speech model (one-time; macOS stores it system-wide).
4. Hold **Right Option**, speak, release. Text appears at your cursor.

The hotkey, activation mode (push-to-talk or toggle), and microphone are configurable from the menu bar icon → Settings.

## Spoken commands

Punctuation and capitalization are automatic. On top of that, Internos recognizes explicit spoken commands after transcription (all on-device, same as everything else):

| You say | You get |
|---|---|
| "new line" | a line break |
| "new paragraph" | a blank line |
| "bullet point milk" | `• milk` (each one starts a new line) |
| "numbered item milk" | `1. milk` (numbers continue; a new paragraph resets to 1) |
| "open quote … close quote" | `“…”` |
| "open parenthesis … close parenthesis" | `(…)` |
| "hashtag yard" | `#yard` |
| "emoji thumbs up" | 👍 |
| "at sign" / "dollar sign" / "percent sign" | `@` / `$` / `%` |
| "snippet calendar link" | your saved snippet, exactly as stored |
| "literal new line" | the words `new line` (escapes exactly one command) |

Everyday words never trigger anything — "bulletproof", "newline", and "a parenthetical remark" stay plain text; commands are matched as whole spoken phrases. Emoji require the spoken word **emoji** before the name, so "she sent me a smiley face" stays literal text. Unknown names are left as spoken. The full set of supported names:

smiley face / smiley 🙂 · winking face 😉 · frowning face 🙁 · laughing face 😂 · crying face 😢 · angry face 😠 · thinking face 🤔 · heart eyes 😍 · heart ❤️ · broken heart 💔 · thumbs up 👍 · thumbs down 👎 · fire 🔥 · party popper 🎉 · rocket 🚀 · star ⭐ · check mark ✅ · cross mark ❌ · clapping hands 👏 · eyes 👀 · shrug 🤷 · skull 💀 · hundred 💯 · wave 👋 · sparkles ✨ · sunglasses 😎 · poop 💩

Matching is case-insensitive and keeps trailing punctuation ("emoji thumbs up." becomes "👍."). The table lives in `App/Sources/TranscriptCommandParser.swift` — PRs adding common names are welcome.

## Personal dictionary and snippets

Settings → Customizations holds two lists, both stored locally in `~/Library/Application Support/<bundle id>/customizations.json`:

- **Replacements** fix words the recognizer consistently gets wrong: say "cube control", get `kubectl`; say "power shell", get `PowerShell`. Matching is case-insensitive and whole-word, and the configured output is typed exactly — it's never re-interpreted as a command or another replacement.
- **Snippets** insert saved text by voice: say "snippet calendar link" and the stored content (multiline, Unicode, whatever) is inserted verbatim. The `snippet` prefix is required, so just saying the name stays ordinary text. Snippets are static text only — no variables, scripts, or lookups — and the settings window will remind you they're stored as plain text, so keep passwords out of them.

Both lists support search, enable/disable, and JSON import/export (Merge or Replace) from the same settings pane.

## Smart cleanup (optional, on-device)

Settings → Processing offers an optional cleanup pass powered by Apple's on-device Foundation Models (the Apple Intelligence local LLM — nothing leaves the Mac):

- **Off** (default) — exactly what you said, plus your commands and replacements.
- **Light** — removes "um"/"uh", accidental repetition, and false starts, and applies self-corrections ("Tuesday, actually Wednesday" → "Wednesday").
- **Polished** — Light, plus smoothing fragments into readable prose.

Cleanup is bounded (two-second deadline, 4,000-character cap) and always fails back to the deterministic text — a model hiccup can never eat your dictation. Snippet contents and replacement outputs never enter the model prompt. Requires an Apple-Intelligence-eligible Mac; without one, Light and Polished show as unavailable and plain dictation is unaffected.

## Command mode (v2)

Select text anywhere, hold the **command key** (default Right Command, configurable), speak an instruction — "fix the spelling", "make this friendlier", "turn this into bullet points" — and release. The selection is rewritten in place by Apple Intelligence's on-device model. Nothing leaves the Mac; the selection is read only at the moment you press the command key, never in the background. Any failure (no Apple Intelligence, timeout, model refusal) changes nothing — your selection stays exactly as it was. The original text is recoverable from **Copy Last Raw Dictation** after a rewrite.

## Live preview, scratch that, and languages (v2)

- **Live preview** — the floating indicator shows your words as they're recognized, while you're still speaking.
- **"Scratch that"** — say it as its own utterance to delete your previous dictation (or command-mode rewrite). One level, same app only.
- **Languages** — Settings → Language lists every locale the on-device recognizer supports; switching may trigger a one-time system model download. Spoken commands (new line, snippet, emoji names) remain English for now; your replacements and snippets work in any language.

## Last dictation recovery

The menu bar keeps your most recent transcript in memory (never on disk): **Copy Last Dictation**, **Paste Last Dictation** (into the app you were just using, with the same Secure-Input and focus checks as live dictation), **Copy Last Raw Dictation** (when smart cleanup changed the text), and **Clear Last Dictation**. Quitting Internos clears it — this is a recovery buffer, not a history.

## Updates

Menu bar icon → **Check for Updates…** compares your version against the latest [GitHub release](../../releases) and offers the download page if you're behind. By default the check runs only when you click it — Internos makes no automatic network calls. If you'd rather be told automatically, Settings has an opt-in "Check for updates at launch" toggle (off by default): one request to GitHub at startup, silent unless an update exists. Changes per release are in [CHANGELOG.md](CHANGELOG.md).

## How it works

Three stages, all local:

1. **Capture** — `AVAudioEngine` mic tap, converted to the analyzer's native format (16 kHz mono)
2. **Transcribe** — Apple's `SpeechAnalyzer` + `SpeechTranscriber` (the same on-device engine behind system dictation, exposed as API in macOS 26)
3. **Insert** — directly into the focused text field via the Accessibility API where the app supports it (the transcript never touches the clipboard at all); otherwise a clipboard swap with a synthetic ⌘V, after which your original clipboard is restored (only if you haven't copied something new in the meantime — a fresh copy always wins)

Measured release-to-inserted-text latency: well under half a second for typical utterances.

If a password field has focus (macOS Secure Input), Internos refuses to inject anything, plays the error sound, and leaves the transcript on the clipboard so nothing is lost. The same applies if you switch apps between releasing the hotkey and the paste landing: Internos won't type into the wrong window.

## Privacy posture

- No network calls in the transcription path — verifiable with Little Snitch or any packet monitor; your audio never leaves the Mac
- No accounts, no telemetry, no transcript storage; settings are the only persisted state
- Insertion prefers the Accessibility API, which bypasses the clipboard entirely. When an app doesn't support it, the fallback briefly places the transcript on the general pasteboard, where macOS services like Universal Clipboard and installed clipboard managers may observe or sync it — that's outside Internos's control. Internos marks the entry with the standard transient/concealed pasteboard types, which well-behaved clipboard managers honor (not guaranteed for all)
- The speech model is downloaded once by macOS itself (Apple's asset CDN) and shared system-wide

Full policy: [PRIVACY.md](PRIVACY.md).

## Building from source

```sh
cd App
./scripts/make-app.sh release   # → App/build/Internos.app
```

Signs with whatever Apple Development identity is in your keychain (stable TCC grants across rebuilds).

### Releasing

```sh
cd App
./scripts/release.sh            # build → sign → notarize → staple → build DMG → notarize DMG
```

This produces both `Internos-<version>.zip` (raw app) and `Internos-<version>.dmg` (drag-to-Applications installer), each notarized and stapled.

One-time setup for a notarized release: `pipx install dmgbuild` (builds the styled installer window), a **Developer ID Application** certificate in the keychain, and stored notary credentials:

```sh
xcrun notarytool store-credentials internos \
  --apple-id you@example.com --team-id TEAMID --password app-specific-password
```

Without those, the script still produces a development-signed zip (fine for your own Macs; Gatekeeper will warn anyone else).

## Repository layout

- `App/` — the application (SwiftPM + bundle assembly script)
- `Spike/` — the throwaway CLI that validated the pipeline first (`Spike/FINDINGS.md` has measured results)
- `Internos-PRD.md` — the product requirements document

## License

[MIT](LICENSE). Provided as-is, no warranty, no support commitment — issues and PRs are welcome but responses aren't guaranteed.
