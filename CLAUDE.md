# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Current state

This repository is in the planning stage. It contains only `Internos-PRD.md`, the product requirements document. There is no source code, build system, or git history yet. When code is added, update this file with actual build/test/run commands.

## What this project is

**Internos** is a planned macOS menu bar utility for fully on-device voice-to-text: hold a global hotkey, speak, release, and the transcription is inserted at the cursor in the frontmost app. The core differentiator is privacy — zero network calls in the transcription path. All speech processing uses Apple's native Speech framework, never a cloud API or bundled third-party model.

Note the naming history: the directory is named "Privox" but that name was rejected (too close to Privoxy). The product name is **Internos**. Use Internos in all new code, bundle identifiers, and documentation.

## Planned architecture (from the PRD)

Three-stage pipeline, mostly wiring around Apple frameworks:

1. **Audio capture** — `AVAudioEngine` input tap, converted via `AnalyzerInputConverter` to the format `SpeechAnalyzer` expects.
2. **Transcription** — `SpeechAnalyzer` + `SpeechTranscriber` (Speech framework, **macOS 26+ hard requirement**; these APIs don't exist earlier). The hotkey-hold-and-release flow may only need finalized results, not volatile ones — simpler. Model assets are ensured on first run via `AssetInventory.assetInstallationRequest`.
3. **Text insertion** — clipboard swap (save clipboard, set transcript, simulate ⌘V, restore) is the MVP approach for cross-app reliability; CGEvent synthetic keystrokes are the fallback option.

Other constraints and decisions:

- Swift + SwiftUI, with AppKit interop for global event monitoring and `NSStatusItem`. Menu-bar-only app (`LSUIElement`, no dock icon).
- Global hotkey via `NSEvent.addGlobalMonitorForEvents` or a Carbon hotkey API wrapper — SwiftUI has no first-class global hotkey API.
- Two permissions required: Microphone and Accessibility. Silently-denied Accessibility permission is the expected #1 failure mode; onboarding for both needs deliberate design.
- Persistence is minimal: settings only (`UserDefaults` or small SwiftData store).
- Apple Silicon only; no Intel support planned.
- Failure behavior: never insert partial/garbage text. Fail visibly (brief error indicator), never silently.
- Latency target: under ~1 second from hotkey release to inserted text for utterances under 15 seconds.

## Non-goals (v1)

No cloud anything (sync, accounts, fallback transcription), no meeting/long-form transcription, no custom vocabulary (Apple's new framework doesn't expose it yet), no Windows/Linux/iOS.

## Milestone order

The PRD sequences work as: (1) command-line spike validating `SpeechAnalyzer`/`SpeechTranscriber` end-to-end before any UI, (2) MVP core loop with hardcoded hotkey and clipboard insertion, (3) menu bar shell and settings, (4) permission onboarding and model download UI, (5) polish and distribution decision. Direct-download-with-notarization is the likely v1 distribution path; App Store sandbox tolerance for global hotkeys + synthetic keystrokes is an open question.

## Open decisions

- Push-to-talk vs. toggle as default interaction (or both from day one).
- Distribution channel (direct vs. App Store) — decide early, it constrains the Accessibility/hotkey approach.
