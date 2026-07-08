# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Current state

Maintain `CHANGELOG.md` (Keep a Changelog format): every user-visible change lands under `[Unreleased]`; on release, retitle that section to the version + date and add the compare link.

v1.0.8 published (GitHub Releases, notarized + stapled DMG and zip; the repo is public, MIT-licensed, with `PRIVACY.md` and `CHANGELOG.md`). `App/scripts/release.sh` runs the full pipeline: build → Developer ID sign → notarize (`notarytool` keychain profile `internos`) → staple → DMG (via `dmgbuild`, `pipx install dmgbuild`) → notarize DMG. `Internos-PRD.md` is the requirements doc. Post-v1 features so far: spoken hashtag/emoji/symbol substitution (`TranscriptPostProcessor.swift`), Check for Updates (manual + opt-in launch check), About panel, branded menu bar icon (`waveform.and.mic`).

- `App/` — the real app (SwiftPM executable, assembled into a bundle). Build: `cd App && ./scripts/make-app.sh release` → `App/build/Internos.app`. Run it with `open build/Internos.app`, or run the inner binary directly to see NSLog output on stderr. Hold Right Option (default) → speak → release → text inserted at cursor. Signs with the local Apple Development identity so TCC grants persist across rebuilds.
  - **For dev iteration, build with `make-app.sh debug`.** Debug builds get a distinct bundle ID (`net.timkennedy.internos.debug`, name "Internos Dev") AND a distinct output path (`App/build/debug/Internos Dev.app`) so they have their own TCC + LaunchServices identity and can NEVER collide with an installed release app. The separate path matters: TCC ties grants to bundle ID + path + signature, and one path alternating between two identities makes permission toggles not stick (fix: `tccutil reset All net.timkennedy.internos.debug`, rebuild, re-grant). Running a same-ID dev copy alongside `/Applications/Internos.app` causes Input Monitoring/Accessibility grants to attach to the wrong binary and appear granted-but-not-registering. Only `make-app.sh release` / `release.sh` use the real `net.timkennedy.internos`.
- `Spike/` — throwaway CLI that validated the pipeline (see `Spike/FINDINGS.md` for measured results). `cd Spike && swift run internos-spike [info|download|file|stream|live]`.

Implementation notes proven in testing: use a fresh `AVAudioEngine` per utterance (a reused engine reports a stale input format after stop/removeTap cycles → silent empty transcripts); the analyzer session is created per utterance with `modelRetention: .processLifetime` to keep the model warm; release→insert latency measured at ~50–70 ms.

## What this project is

**Internos** is a macOS menu bar utility for fully on-device voice-to-text: hold a global hotkey, speak, release, and the transcription is inserted at the cursor in the frontmost app. The core differentiator is privacy — zero network calls in the transcription path. All speech processing uses Apple's native Speech framework, never a cloud API or bundled third-party model.

Note the naming history: the directory is named "Privox" but that name was rejected (too close to Privoxy). The product name is **Internos**. Use Internos in all new code, bundle identifiers, and documentation.

## Planned architecture (from the PRD)

Three-stage pipeline, mostly wiring around Apple frameworks:

1. **Audio capture** — `AVAudioEngine` input tap, converted to the format `SpeechAnalyzer` expects, yielded as `AnalyzerInput`. The buffer format must match `SpeechTranscriber.bestAvailableAudioFormat` or transcription **silently returns nothing** (no error) — validate this first in the spike.
2. **Transcription** — `SpeechAnalyzer` + `SpeechTranscriber` (Speech framework, **macOS 26+ hard requirement**; these APIs don't exist earlier). The hotkey-hold-and-release flow may only need finalized results, not volatile ones — simpler. Model assets are ensured on first run via `AssetInventory.assetInstallationRequest`; the model is stored system-wide (no app-size cost) and shared across apps. `en-US` only for v1.
3. **Text insertion** — clipboard swap (save clipboard, set transcript, simulate ⌘V, restore) is the MVP approach for cross-app reliability; CGEvent synthetic keystrokes are the fallback option. **Both end in a synthesized keystroke, so both are blocked by macOS Secure Input** in password/sensitive fields (clipboard swap is not immune — its ⌘V is synthesized). Preflight with `IsSecureEventInputEnabled()` and fail visibly rather than dropping the transcript.

Other constraints and decisions:

- Swift + SwiftUI, with AppKit interop for global event monitoring and `NSStatusItem`. Menu-bar-only app (`LSUIElement`, no dock icon).
- Global hotkey via a `listenOnly` `CGEventTap` (preferred — needs only Input Monitoring) rather than `NSEvent.addGlobalMonitorForEvents` (needs Accessibility); a Carbon `RegisterEventHotKey` wrapper is an alternative. SwiftUI has no first-class global hotkey API. A `listenOnly` tap observes but does not consume the key.
- **Three** permissions may be required, each a distinct TCC grant in its own System Settings pane: **Microphone** (capture), **Input Monitoring** (the `CGEventTap` hotkey; `CGPreflight`/`CGRequestListenEventAccess`), and **Accessibility** (synthetic keystroke/paste insertion; `AXIsProcessTrustedWithOptions`). Silently-denied permissions are the #1 failure mode; all three need deliberate onboarding.
- Persistence is minimal: settings only (`UserDefaults` or small SwiftData store).
- Apple Silicon only; no Intel support planned. `en-US` only for v1.
- Failure behavior: never insert partial/garbage text. Fail visibly (brief error indicator), never silently — explicitly includes the Secure Input case.
- Latency target: under ~1 second from hotkey release to inserted text for utterances under 15 seconds.
- Optional stretch: on-device text cleanup (filler removal, self-correction) via the **Foundation Models** framework (macOS 26, on-device ~3B LLM, fixed 4096-token context window). Not on the core transcription path; requires an Apple-Intelligence-eligible device.

## Non-goals (v1)

No cloud anything (sync, accounts, fallback transcription), no meeting/long-form transcription, no multi-language (en-US only), no Windows/Linux/iOS. Custom vocabulary is out for v1: the spike confirmed `AnalysisContext.contextualStrings` exists in the SDK but is empirically inert for `SpeechTranscriber` (see `Spike/FINDINGS.md`); a user dictionary would have to be a post-processing pass. Use `SpeechTranscriber(.transcription)`, not `DictationTranscriber` (volatile-only finalization, worse accuracy in testing).

## Milestone order

The PRD sequences work as: (1) command-line spike validating `SpeechAnalyzer`/`SpeechTranscriber` end-to-end before any UI (confirm en-US asset flow, `bestAvailableAudioFormat` match, and whether any custom-vocabulary API exists), (2) MVP core loop with hardcoded hotkey and clipboard insertion plus Secure-Input preflight, (3) menu bar shell and settings, (4) permission onboarding (Mic + Input Monitoring + Accessibility) and model download UI, (5) polish, sign + notarize. **Distribution is decided: direct download** (GitHub Releases, possibly TestFlight for beta), signed + notarized — not the Mac App Store. Note: the hotkey alone could ship sandboxed; it's the insertion step (Accessibility) that the App Store sandbox restricts.

## Open decisions

- Push-to-talk vs. toggle as default interaction (or both from day one).
