# Internos

**Dictation that stays between us.**

Internos is a macOS menu bar utility for fully on-device voice-to-text: hold a hotkey, speak, release, and the transcription appears at your cursor in whatever app you're using. All speech processing runs on your Mac using Apple's native Speech framework. No audio or text ever leaves the machine — zero network calls in the transcription path.

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

Punctuation and capitalization are automatic. On top of that, Internos rewrites a few spoken patterns after transcription (all on-device, same as everything else):

| You say | You get |
|---|---|
| "hashtag yard" | `#yard` |
| "emoji thumbs up" | 👍 |
| "at sign" | `@` |
| "dollar sign" | `$` |
| "percent sign" | `%` |

Emoji require the spoken word **emoji** before the name, so saying "she sent me a smiley face" stays literal text. About 28 common emoji names are supported (smiley face, winking face, heart, thumbs up/down, fire, rocket, party popper, check mark, shrug, skull, hundred, sparkles, sunglasses, …). Unknown names are left as spoken.

## Updates

Menu bar icon → **Check for Updates…** compares your version against the latest [GitHub release](../../releases) and offers the download page if you're behind. By default the check runs only when you click it — Internos makes no automatic network calls. If you'd rather be told automatically, Settings has an opt-in "Check for updates at launch" toggle (off by default): one request to GitHub at startup, silent unless an update exists. Changes per release are in [CHANGELOG.md](CHANGELOG.md).

## How it works

Three stages, all local:

1. **Capture** — `AVAudioEngine` mic tap, converted to the analyzer's native format (16 kHz mono)
2. **Transcribe** — Apple's `SpeechAnalyzer` + `SpeechTranscriber` (the same on-device engine behind system dictation, exposed as API in macOS 26)
3. **Insert** — clipboard swap with a synthetic ⌘V, then your original clipboard is restored

Measured release-to-inserted-text latency: well under half a second for typical utterances.

If a password field has focus (macOS Secure Input), Internos refuses to inject anything, plays the error sound, and leaves the transcript on the clipboard so nothing is lost.

## Privacy posture

- No network calls in the transcription path — verifiable with Little Snitch or any packet monitor
- No accounts, no telemetry, no transcript storage; settings are the only persisted state
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
