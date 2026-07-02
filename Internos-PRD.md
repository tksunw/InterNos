# PRD: Internos — Local Voice-to-Text for macOS

**Status:** Draft v0.1
**Owner:** Tim Kennedy
**Name:** Internos *(Latin "inter nos" — "between us")*
**Tagline (working):** *Internos — dictation that stays between us.*

---

## 1. Summary

Internos is a macOS menu bar utility that lets a user hold a global hotkey, speak, and have the transcribed text inserted wherever their cursor is — in any app. Unlike Wispr Flow and similar tools, Internos does **all** speech processing on-device using Apple's native Speech framework (`SpeechAnalyzer`/`SpeechTranscriber`), so no audio or text ever leaves the Mac. That's the whole pitch: dictation that's genuinely private, not "private-ish with a cloud fallback."

**Analogy:** think of it as a **local dictation stenographer who lives in your Mac** rather than a **court reporter who phones the transcript to a courthouse downtown**. Same output, but nothing ever leaves the room.

---

## 2. Problem Statement

Voice-to-text tools like Wispr Flow, Superwhisper, and macOS's own dictation-adjacent features are genuinely useful for people who type slower than they think or who deal with RSI/wrist strain. But most of the popular ones either:

- Send audio to a cloud API (privacy concern, plus a dependency on network + a vendor's uptime/policies), or
- Require a paid subscription tied to cloud inference cost, or
- Use bundled third-party models (e.g., local Whisper builds) that are large, not deeply OS-integrated, and not automatically kept current by Apple's OS updates.

There's a gap for privacy-conscious professionals (security engineers, healthcare, legal, anyone under compliance requirements, or just people who don't want a hot mic phoning home) who want fast, accurate, **fully local** dictation that feels native to macOS.

---

## 3. Goals

- Press-and-hold (or toggle) a global hotkey from anywhere on macOS to capture audio.
- Transcribe entirely on-device using Apple's `SpeechAnalyzer`/`SpeechTranscriber` — zero network calls for the core transcription path.
- Insert the resulting text at the current cursor position in the frontmost app (Mail, Slack, VS Code, Terminal, Notes, whatever).
- Feel instant: sub-second perceived latency from "stop talking" to "text appears" for short-to-medium utterances.
- Be a lightweight menu bar app — not a full window-based application the user has to context-switch into.

### Non-Goals (v1)

- Multi-user/team features, cloud sync of transcripts, or any account system.
- Meeting transcription / long-form recording of ongoing calls (that's a different product shape — closer to Notes/Voice Memos with speaker diarization).
- Custom vocabulary / domain-specific terminology tuning (Apple's new framework doesn't support this yet — see Risks).
- Windows/Linux support. This is a macOS-native bet.
- iOS companion app (though architecture should not preclude it later — you already have the muscle memory from GLP Health Journey).

---

## 4. Target User

Primary persona: **privacy-conscious power users** — the kind of person who reads a privacy policy before enabling an integration (you've done exactly this with Anthropic's, for context). Specifically:

- Engineers/IT/security professionals who are wary of audio leaving their machine, possibly under NDA or compliance constraints.
- Writers, researchers, and note-takers who want fast capture without a subscription treadmill.
- Anyone who's tried Wispr Flow / Superwhisper, likes the workflow, but is uneasy about the cloud dependency or the price.

---

## 5. Core User Flow

1. User is in any app (Mail, Slack, a terminal, whatever) with a text cursor active.
2. User presses and holds the configured hotkey (default suggestion: a rarely-used combo like `Fn` held, or `Right Option` double-tap — needs testing for conflicts with system shortcuts).
3. A small floating indicator appears (waveform or pulsing dot) near the cursor or in a fixed corner, confirming recording is active.
4. User speaks. Release the hotkey (or tap again if using toggle mode) to stop.
5. Internos transcribes the captured audio buffer on-device.
6. Text is inserted at the cursor via simulated keystrokes or clipboard-paste-and-restore, and the indicator disappears.
7. If transcription is empty or fails, indicator shows a brief error state and nothing is inserted (no silent partial garbage text).

---

## 6. Functional Requirements (MVP)

| # | Requirement | Notes |
|---|---|---|
| F1 | Global hotkey registration (push-to-talk and/or toggle mode) | Configurable in settings; needs to coexist with system shortcuts and per-app shortcuts |
| F2 | Audio capture from default/selected input device | `AVAudioEngine` tap, buffer streamed to the analyzer |
| F3 | On-device transcription via `SpeechAnalyzer` + `SpeechTranscriber` | Use `.transcription` or a live-appropriate preset; handle volatile vs. finalized results |
| F4 | Text insertion at cursor in frontmost app | Likely via synthetic keyboard events (CGEvent) or clipboard swap-paste-restore for reliability across apps |
| F5 | Menu bar UI: status icon, recording indicator, settings | No dock icon; lives entirely in the menu bar (`LSUIElement`) |
| F6 | Model asset management | First-run: check if the `SpeechTranscriber` model asset is installed; if not, trigger `AssetInventory` download with a visible progress state |
| F7 | Microphone + Accessibility permission handling | Both are required (mic for capture, Accessibility for synthetic keystroke insertion) — needs clear onboarding since macOS permission prompts are notoriously easy to fumble |
| F8 | Basic settings: hotkey remap, input device selection, launch-at-login | Table stakes for this category of utility |
| F9 | Visual + audio confirmation of state (recording / processing / done / error) | Small, unobtrusive — this is the kind of app that should almost disappear when working correctly |

### Stretch (v1.1+, not MVP)

- Light on-device text cleanup/formatting pass (filler word removal, punctuation correction) using Apple's on-device **Foundation Models** framework — this is the same "on-device LLM" layer Apple introduced alongside `SpeechAnalyzer`, so it's a natural, still-fully-local extension rather than a new dependency.
- Per-app formatting profiles (e.g., no auto-capitalization in a terminal, markdown-friendly formatting in Notes).
- History/undo — a small local log of recent transcriptions in case an insertion goes to the wrong window.
- Custom vocabulary once/if Apple exposes it on the new framework.

---

## 7. Technical Architecture

**Analogy:** picture three stations on an assembly line — a **microphone tap** (raw audio in), a **transcription engine** (Apple's `SpeechAnalyzer` doing the work), and a **typist** (the insertion layer putting text where it belongs). Your app is mostly the wiring and UI around stations Apple already built and maintains; that's the leverage.

- **Language/Frameworks:** Swift, SwiftUI for settings/menu bar UI, `AppKit` interop where SwiftUI doesn't reach (global event monitoring, `NSStatusItem`).
- **Audio capture:** `AVAudioEngine` with an input tap, converted via `AnalyzerInputConverter` to the format `SpeechAnalyzer` expects.
- **Transcription:** `SpeechAnalyzer` + `SpeechTranscriber` module (Speech framework, macOS 26+). Handle both volatile (in-progress) and finalized results if you want a live-preview feel; for a hotkey-hold-and-release flow you may only need finalized results, which simplifies things considerably.
- **Model assets:** `AssetInventory.assetInstallationRequest` to ensure the transcription model is present on first run; models can be shared across apps once downloaded once on a device.
- **Global hotkey:** `NSEvent.addGlobalMonitorForEvents` or a Carbon-era hotkey API wrapped in Swift (still commonly used for this exact purpose since SwiftUI has no first-class global hotkey API).
- **Text insertion:** Two viable approaches —
  - **Clipboard swap:** copy current clipboard, set clipboard to transcribed text, simulate ⌘V, restore original clipboard. Reliable across almost all apps, slight risk of visible clipboard flicker or race conditions with fast typers.
  - **Synthetic keystrokes via CGEvent:** types the text out character-by-character. More "native" feeling but slower for long transcripts and can trip up in apps with custom text handling (like some Electron apps).
  - Recommendation: start with clipboard-swap for MVP reliability, keep CGEvent as a fallback/option.
- **Permissions:** Microphone (`NSMicrophoneUsageDescription`) and Accessibility (System Settings → Privacy & Security → Accessibility) — both need clear first-run onboarding screens, since a silently-denied Accessibility permission is the single most common failure mode for this class of app.
- **Persistence:** Minimal — settings only, via `UserDefaults` or a tiny SwiftData store if you want it queryable later (consistent with your GLP Health Journey stack).

---

## 8. Platform Requirements

- **macOS 26 (Tahoe) or later** — hard requirement, since `SpeechAnalyzer`/`SpeechTranscriber` don't exist on earlier OS versions. `SFSpeechRecognizer` (the legacy API) could serve as a fallback for older OS versions, but that reopens questions about accuracy/latency parity and is worth treating as an explicit v2 decision rather than baking in now.
- **Apple Silicon** — on-device model performance is a major differentiator on Apple Silicon; Intel support is a separate discussion (likely not worth the engineering time given the OS floor already excludes most Intel Macs still in service).

---

## 9. Non-Functional Requirements

- **Privacy:** No network calls in the core transcription path. This should be verifiable/auditable — worth stating explicitly in a privacy page and ideally something you could demonstrate (e.g., via Little Snitch logs) as a trust-building feature, not just a claim.
- **Latency:** Target under ~1 second from hotkey release to text appearing for utterances under 15 seconds.
- **Resource usage:** Should idle at near-zero CPU when not actively recording/transcribing.
- **Reliability:** Failed transcription should never insert garbage text or silently eat what the user said — fail loud (small visible error), not quiet.

---

## 10. Success Metrics (self-directed / indie context)

Since this isn't being built against a team OKR, "success" is probably better framed as:

- It fully replaces your own use of any cloud dictation tool within the first few weeks of daily use.
- Insertion works reliably (no wrong-window pastes, no clipboard corruption) across your actual daily app rotation (Slack, Mail, terminal, Obsidian, code editors).
- If you choose to ship it publicly: App Store approval on first submission, and organic interest from the "privacy-conscious dictation" niche (there's a real, vocal audience for this — Wispr Flow's own user base complains about the cloud dependency regularly).

---

## 11. Risks & Open Questions

| Risk / Question | Notes |
|---|---|
| No custom vocabulary support yet | `SpeechAnalyzer` doesn't currently expose the keyword-boosting feature `SFSpeechRecognizer` had. If you dictate a lot of technical/proper nouns (Palo Alto, Azure resource names, etc.), accuracy on jargon may lag behind cloud alternatives until Apple adds this. |
| Global hotkey conflicts | Need to test against common app shortcuts and system-reserved combos before picking a default. |
| Accessibility permission friction | This is the #1 support-ticket generator for apps in this category — budget real design time for onboarding. |
| App Store distribution vs. direct download | Global hotkeys + synthetic keystrokes + Accessibility permissions sit right at the edge of what the App Store sandbox tolerates. Worth a quick feasibility check before committing to a distribution channel — direct-download-with-notarization may be the more realistic v1 path, with an App Store submission attempted later. |
| Model download size/time on first run | Needs a clear, honest first-run UI so it doesn't feel broken while the asset installs. |
| Naming/trademark | Landed on **Internos**. "Voxer" is actively used and trademarked by an established push-to-talk messaging company — avoided. "Privox" was close enough to the existing open-source **Privoxy** proxy tool to risk confusion with the exact privacy-conscious audience being targeted — avoided. Internos is used by an unrelated Miami-based B2B managed IT services company; different product category (services vs. downloadable macOS software) keeps legal risk low, but expect to share search results and likely won't get the bare .com. Worth a quick USPTO TESS check and App Store name search before committing further, since neither has been formally run yet. |

---

## 12. Rough Milestones

1. **Spike:** Get `SpeechAnalyzer`/`SpeechTranscriber` working end-to-end in a throwaway command-line tool (similar to the community "Yap" utility) — validates the API on your hardware before any UI work.
2. **MVP core loop:** Hotkey → capture → transcribe → clipboard-paste insertion, no settings UI, hardcoded hotkey.
3. **Menu bar shell:** Status item, recording indicator, minimal settings (hotkey remap, input device).
4. **Permission onboarding:** First-run flow for Mic + Accessibility, model asset download UI.
5. **Polish pass:** Error states, launch-at-login, icon/branding, distribution decision (direct vs. App Store).
6. **Dogfood:** Daily-drive it yourself for 1–2 weeks before deciding on wider distribution.

---

## 13. Open Decisions For You

- Push-to-talk vs. toggle as the default interaction (or support both from day one).
- Direct distribution vs. App Store as the primary channel — this affects how much of the Accessibility/global-hotkey approach is even viable, so it's worth deciding early rather than after the architecture is set.
