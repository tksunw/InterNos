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

1. Download `Internos-x.y.z.zip` from [Releases](../../releases), unzip, drag `Internos.app` to `/Applications`.
2. Launch it. The setup window walks you through the three permissions it needs:
   - **Microphone** — capturing your voice while the hotkey is held
   - **Input Monitoring** — detecting the hotkey anywhere in macOS
   - **Accessibility** — inserting text at your cursor
3. Let it download the speech model (one-time; macOS stores it system-wide).
4. Hold **Right Option**, speak, release. Text appears at your cursor.

The hotkey, activation mode (push-to-talk or toggle), and microphone are configurable from the menu bar icon → Settings.

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

## Building from source

```sh
cd App
./scripts/make-app.sh release   # → App/build/Internos.app
```

Signs with whatever Apple Development identity is in your keychain (stable TCC grants across rebuilds).

### Releasing

```sh
cd App
./scripts/release.sh            # build → sign → zip → notarize → staple
```

One-time setup for a notarized release: a **Developer ID Application** certificate in the keychain, and stored notary credentials:

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

TBD.
