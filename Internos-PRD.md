# PRD: Internos — Local Voice-to-Text for macOS

**Status:** Draft v0.2 *(revised 2026-07-02 after multi-source technical validation — see §14)*
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
- Custom vocabulary / domain-specific terminology tuning at the recognition layer (the new `SpeechAnalyzer` API *appears* not to expose phrase-boosting like legacy `SFSpeechRecognizer` did — this is **unconfirmed**, see Risks. A Foundation Models find-and-replace pass is a possible workaround.).
- Multi-language support. **v1 targets `en-US` only** (the primary users — Tim, wife, son — all dictate in US English). Other locales are a later decision, not a v1 constraint.
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
7. If transcription is empty or fails, **or if macOS Secure Input is active** (which blocks the paste/keystroke insertion — see §7), the indicator shows a brief error state and nothing is inserted (no silent partial garbage text). The transcript should be recoverable (e.g., left on the clipboard or in the history log) rather than lost.

---

## 6. Functional Requirements (MVP)

| # | Requirement | Notes |
|---|---|---|
| F1 | Global hotkey registration (push-to-talk and/or toggle mode) | Configurable in settings; needs to coexist with system shortcuts and per-app shortcuts |
| F2 | Audio capture from default/selected input device | `AVAudioEngine` tap, buffer streamed to the analyzer |
| F3 | On-device transcription via `SpeechAnalyzer` + `SpeechTranscriber` | Use `.transcription` or a live-appropriate preset; handle volatile vs. finalized results |
| F4 | Text insertion at cursor in frontmost app | Clipboard swap-paste-restore (MVP) or synthetic CGEvent keystrokes (fallback). **Both end in a synthesized ⌘V / keystroke, so both are blocked by macOS Secure Input** — see F4a and §7 |
| F4a | Secure Input detection + fail-loud | Before inserting, check `IsSecureEventInputEnabled()`. If active (or stuck), do **not** attempt insertion; show the error state (F9) and preserve the transcript. This is the concrete mechanism behind the "never insert garbage" rule |
| F5 | Menu bar UI: status icon, recording indicator, settings | No dock icon; lives entirely in the menu bar (`LSUIElement`) |
| F6 | Model asset management | First-run: check if the `SpeechTranscriber` model asset is installed; if not, trigger `AssetInventory.assetInstallationRequest` → `downloadAndInstall()` with a visible progress state. Model lives in shared system storage (no app-size or app-memory cost; shared across apps on the device) |
| F7 | Microphone + Accessibility + Input Monitoring permission handling | **Three** permissions may be required, not two: Microphone (capture), Input Monitoring (a `listenOnly` `CGEventTap` for hotkey detection), and Accessibility (synthetic keystroke/paste insertion). Each is a distinct TCC permission in its own System Settings pane — see §7. Needs clear onboarding since macOS permission prompts are notoriously easy to fumble |
| F8 | Basic settings: hotkey remap, input device selection, launch-at-login | Table stakes for this category of utility |
| F9 | Visual + audio confirmation of state (recording / processing / done / error) | Small, unobtrusive — this is the kind of app that should almost disappear when working correctly |

### Implemented post-v1 (2026-07, feature handoff)

The following former stretch items shipped as a staged transcript pipeline
(`TranscriptCommandParser` → optional Foundation Models cleanup → user
replacements → renderer), with protected segments guaranteeing snippet and
replacement output is never re-processed or sent to the model:

- **Smart cleanup** — optional on-device Foundation Models pass (Off/Light/Polished,
  default Off), one fresh `LanguageModelSession` per utterance, 2 s deadline,
  4,000-char input cap, output validation, soft fallback to deterministic text.
  Covers filler removal and self-correction ("backtrack") behavior.
- **Personal dictionary / replacements** — deterministic post-transcription
  find-and-replace (the recognition layer is inert, per the spike), persisted in
  `~/Library/Application Support/<bundle id>/customizations.json`.
- **Voice-triggered snippets** — "snippet <name>" inserts exact stored text.
- **Structured voice commands** — new line/paragraph, bullet/numbered lists,
  quotes, parentheses, and a `literal` escape.
- **Volatile last-transcript recovery** — Copy/Paste/Copy Raw/Clear Last Dictation
  menu items backed by a memory-only store (deliberately not a persisted history).

### Stretch (v2+, not built)

- **Command mode** — a separate hotkey to transform highlighted text by voice (rewrite / fix / translate), inserting inline or replacing the selection. This is Wispr Flow's "Command Mode." Explicitly a **v2+ non-goal** for now, but named so the architecture doesn't preclude it.
- Per-app formatting profiles (e.g., no auto-capitalization in a terminal, markdown-friendly formatting in Notes).
- Persistent transcription history (the volatile recovery buffer above is intentionally memory-only).

---

## 7. Technical Architecture

**Analogy:** picture three stations on an assembly line — a **microphone tap** (raw audio in), a **transcription engine** (Apple's `SpeechAnalyzer` doing the work), and a **typist** (the insertion layer putting text where it belongs). Your app is mostly the wiring and UI around stations Apple already built and maintains; that's the leverage.

- **Language/Frameworks:** Swift, SwiftUI for settings/menu bar UI, `AppKit` interop where SwiftUI doesn't reach (global event monitoring, `NSStatusItem`).
- **Audio capture:** `AVAudioEngine` with an input tap, converted to the format `SpeechAnalyzer` expects, then yielded as `AnalyzerInput`. **Footgun to validate in the spike:** the buffer format must match `SpeechTranscriber.bestAvailableAudioFormat` — hardware input is often 48 kHz, and a format mismatch causes transcription to **silently return nothing** rather than error. Get this right first.
- **Transcription:** `SpeechAnalyzer` + `SpeechTranscriber` module (Speech framework, macOS 26+). Handle both volatile (in-progress) and finalized results if you want a live-preview feel; for a hotkey-hold-and-release flow you may only need finalized results, which simplifies things considerably.
- **Model assets:** `AssetInventory.assetInstallationRequest` to ensure the transcription model is present on first run; models can be shared across apps once downloaded once on a device.
- **Global hotkey:** prefer a **`listenOnly` `CGEventTap`** over `NSEvent.addGlobalMonitorForEvents`. Per Apple DTS (forum thread 707680), the `NSEvent` global monitor requires the **Accessibility** privilege for "weird historical reasons," whereas a `CGEventTap` requires only **Input Monitoring** — a lighter permission that's even available to sandboxed / App Store apps. Trade-off: a `listenOnly` tap observes but cannot *suppress* the hotkey from reaching the frontmost app (fine for hold/release detection; a `defaultTap` that consumes events would re-trigger the Accessibility requirement). A Carbon `RegisterEventHotKey` wrapper remains a viable alternative for a fixed combo. SwiftUI has no first-class global hotkey API.
- **Text insertion:** Two approaches, both of which end in a synthesized keystroke and are therefore **both subject to Secure Input** (see below) —
  - **Clipboard swap:** copy current clipboard, set clipboard to transcribed text, simulate ⌘V, restore original clipboard. Reliable across almost all apps, slight risk of visible clipboard flicker or race conditions with fast typers. **Note: the ⌘V is itself synthesized, so this is NOT immune to Secure Input** — it is not the "safe" option the earlier draft implied.
  - **Synthetic keystrokes via CGEvent:** types the text out character-by-character. More "native" feeling but slower for long transcripts and can trip up in apps with custom text handling (like some Electron apps).
  - Recommendation: start with clipboard-swap for MVP reliability, keep CGEvent as a fallback/option. Both require **Accessibility**.
- **Secure Input (`EnableSecureEventInput`):** macOS blocks synthetic keystroke injection (including a synthesized ⌘V) while focus is in a password/sensitive field. It can also get **stuck enabled** when a background app requests it and never releases it (password managers, iTerm/Terminal are common offenders), which kills injection system-wide until resolved. Internos must **detect this before inserting** (`IsSecureEventInputEnabled()`), fail loud, and preserve the transcript rather than dropping it (F4a).
- **Permissions (up to three distinct TCC grants, each its own System Settings pane):**
  - **Microphone** (`NSMicrophoneUsageDescription`) — audio capture.
  - **Input Monitoring** — the `CGEventTap` hotkey listener. Check/request via `CGPreflightListenEventAccess()` / `CGRequestListenEventAccess()`. *This was omitted in v0.1.*
  - **Accessibility** (`AXIsProcessTrustedWithOptions`, System Settings → Privacy & Security → Accessibility) — synthetic keystroke/paste insertion.
  - A silently-denied permission is the single most common failure mode for this class of app; all three need clear first-run onboarding. (If you ever switch the hotkey to an `NSEvent` global monitor, that folds hotkey detection into the Accessibility grant and drops the Input Monitoring requirement — a design trade-off, not a free simplification.)
- **Persistence:** Minimal — settings only, via `UserDefaults` or a tiny SwiftData store if you want it queryable later (consistent with your GLP Health Journey stack).

---

## 8. Platform Requirements

- **macOS 26 (Tahoe) or later** — hard requirement, since `SpeechAnalyzer`/`SpeechTranscriber` don't exist on earlier OS versions. `SFSpeechRecognizer` (the legacy API) could serve as a fallback for older OS versions, but that reopens questions about accuracy/latency parity and is worth treating as an explicit v2 decision rather than baking in now.
- **Apple Silicon** — on-device model performance is a major differentiator on Apple Silicon; Intel support is a separate discussion (likely not worth the engineering time given the OS floor already excludes most Intel Macs still in service).
- **Language: `en-US` only for v1** — matches the actual user set (Tim + family). Confirm `en-US` is present in `SpeechTranscriber.supportedLocales` / installed-locale check on first run.
- **Foundation Models (only if the stretch cleanup pass is built):** additionally requires an Apple-Intelligence-eligible device with the feature enabled — a runtime gate *beyond* the OS-version floor. The core transcription path does not depend on it.

---

## 9. Non-Functional Requirements

- **Privacy:** No network calls in the core transcription path. This should be verifiable/auditable — worth stating explicitly in a privacy page and ideally something you could demonstrate (e.g., via Little Snitch logs) as a trust-building feature, not just a claim.
- **Latency:** Target under ~1 second from hotkey release to text appearing for utterances under 15 seconds.
- **Resource usage:** Should idle at near-zero CPU when not actively recording/transcribing.
- **Reliability:** Failed transcription should never insert garbage text or silently eat what the user said — fail loud (small visible error), not quiet. This explicitly includes the **Secure Input** case (F4a): detect it before inserting, show the error, and keep the transcript recoverable.

---

## 10. Success Metrics (self-directed / indie context)

Since this isn't being built against a team OKR, "success" is probably better framed as:

- It fully replaces your own use of any cloud dictation tool within the first few weeks of daily use.
- Insertion works reliably (no wrong-window pastes, no clipboard corruption) across your actual daily app rotation (Slack, Mail, terminal, Obsidian, code editors).
- If you choose to ship it publicly: a clean signed + notarized direct-download build (GitHub Releases, possibly TestFlight for beta), and organic interest from the "privacy-conscious dictation" niche (there's a real, vocal audience for this — Wispr Flow is confirmed cloud-only, and its own user base complains about the cloud dependency regularly).

---

## 11. Risks & Open Questions

| Risk / Question | Notes |
|---|---|
| Custom vocabulary: API present but **inert** *(resolved by spike, 2026-07-02)* | `AnalysisContext.contextualStrings` **does exist** in the macOS 26 SDK (the v0.1 "no such API" claim was wrong), but empirically has **no effect** on `SpeechTranscriber` output (tested: "Internos" still misrecognized with the term supplied). A full custom-LM path exists via `DictationTranscriber.ContentHint.customizedLanguage`, but that module finalized poorly and was less accurate in testing. **Decision:** treat recognition-layer vocabulary as unavailable for v1; a user dictionary would be a Foundation Models find-and-replace pass. See `Spike/FINDINGS.md`. |
| **Secure Input blocks text insertion** *(new)* | macOS Secure Input blocks synthesized keystrokes **including the ⌘V used by clipboard-swap** — so the "safe" MVP path is not immune. It can also get stuck enabled by a backgrounded app. Must detect (`IsSecureEventInputEnabled()`) and fail loud (F4a). |
| Global hotkey conflicts | Need to test against common app shortcuts and system-reserved combos before picking a default. A `listenOnly` `CGEventTap` observes but does not consume the key, so the hotkey still reaches the frontmost app — pick a combo that's inert there. |
| Permission friction (now up to **three**) | Microphone + Input Monitoring + Accessibility, each a separate TCC grant. This class of app is the #1 support-ticket generator for exactly this reason — budget real design time for a staged, three-step onboarding. |
| ~~App Store vs. direct download~~ → **decided: direct download** | **Resolved (2026-07-02):** primary channel is signed + notarized **direct download from GitHub Releases** (possibly TestFlight for beta), not the Mac App Store. Nuance from research: the *hotkey* alone (via `listenOnly` `CGEventTap` + Input Monitoring) could ship sandboxed/App Store; it's the *insertion* step (synthetic ⌘V / CGEvent needing Accessibility) that the sandbox restricts. Not a v1 concern given the direct-download decision. |
| Foundation Models context cap | *(Only if the stretch cleanup pass is built.)* Fixed **4096-token** context window — keep cleanup prompts bounded; don't feed very long transcripts wholesale. |
| Model download size/time on first run | Needs a clear, honest first-run UI so it doesn't feel broken while the asset installs. Model is stored system-wide (no app-size cost) and shared across apps, so it may already be present if another app installed the `en-US` asset. |
| Naming/trademark | Landed on **Internos**. "Voxer" is actively used and trademarked by an established push-to-talk messaging company — avoided. "Privox" was close enough to the existing open-source **Privoxy** proxy tool to risk confusion with the exact privacy-conscious audience being targeted — avoided. Internos is used by an unrelated Miami-based B2B managed IT services company; different product category (services vs. downloadable macOS software) keeps legal risk low, but expect to share search results and likely won't get the bare .com. Worth a quick USPTO TESS check and App Store name search before committing further, since neither has been formally run yet. |

---

## 12. Rough Milestones

1. **Spike:** Get `SpeechAnalyzer`/`SpeechTranscriber` working end-to-end in a throwaway command-line tool (similar to the community "Yap" utility) — validates the API on your hardware before any UI work. **Confirm three things here:** (a) `en-US` model download/asset flow, (b) the `bestAvailableAudioFormat` match (or transcription silently returns nothing), (c) whether any custom-vocabulary/phrase-boosting API exists (open question from §11).
2. **MVP core loop:** Hotkey (`listenOnly` `CGEventTap`) → capture → transcribe → clipboard-paste insertion **with a Secure-Input preflight check**, no settings UI, hardcoded hotkey.
3. **Menu bar shell:** Status item, recording indicator, minimal settings (hotkey remap, input device).
4. **Permission onboarding:** First-run flow for **Mic + Input Monitoring + Accessibility** (three panes), model asset download UI.
5. **Polish pass:** Error states (incl. Secure Input), launch-at-login, icon/branding, sign + notarize for direct download.
6. **Dogfood:** Daily-drive it yourself for 1–2 weeks before deciding on wider distribution.

---

## 13. Open Decisions For You

- Push-to-talk vs. toggle as the default interaction (or support both from day one).
- ~~Direct distribution vs. App Store~~ — **decided: direct download** (signed + notarized, GitHub Releases, possibly TestFlight for beta). See §11.

---

## 14. Research Validation Notes (2026-07-02)

This revision (v0.1 → v0.2) folds in a multi-source, adversarially fact-checked technical review. Summary of what changed and why:

**Confirmed as correct (no change needed):**
- SpeechAnalyzer + SpeechTranscriber are new in macOS 26.0+, fully on-device, streaming (volatile → finalized), and supersede `SFSpeechRecognizer`. [Apple WWDC25 s277; developer.apple.com/documentation/speech/speechtranscriber]
- The AVAudioEngine-tap → format-convert → `AnalyzerInput` pipeline is the documented approach. [WWDC25 s277]
- Model assets via `AssetInventory.assetInstallationRequest`, stored system-wide, shared across apps, no app-size/memory cost. [WWDC25 s277]
- Foundation Models is a real on-device ~3B LLM (offline, private, no app-size cost) suited to a bounded cleanup pass. [developer.apple.com/documentation/foundationmodels; WWDC25 s286]
- Wispr Flow is **cloud-only** (documented server-side processing states) — the on-device privacy bet is a genuine differentiator. [docs.wisprflow.ai; wisprflow.ai/features]

**Corrected / added:**
- **Input Monitoring** is a distinct permission the v0.1 draft omitted; a `listenOnly` `CGEventTap` needs it (not Accessibility). [Apple DTS, developer.apple.com/forums/thread/707680]
- **Secure Input** blocks clipboard-swap paste too (the ⌘V is synthesized), not just CGEvent — added detection + fail-loud requirement (F4a). [espanso.org/docs/troubleshooting/secure-input, corroborated by KeePassXC/1Password/Keyboard Maestro]
- **App Store constraint reframed:** the hotkey can ship sandboxed; the *insertion* step is what the sandbox restricts. Moot given the direct-download decision. [forum 707680]
- **Foundation Models 4096-token context cap** noted for the cleanup pass. [Apple TN3193; InfoQ 2026-03]
- **Competitor features surfaced:** Wispr's Smart Formatting (filler removal), Backtrack (self-correction), Command Mode, and auto-learning dictionary — added to stretch/non-goals.

**Resolved by the spike (2026-07-02, see `Spike/FINDINGS.md`):**
- Custom vocabulary: `AnalysisContext.contextualStrings` exists in the SDK but is empirically inert for `SpeechTranscriber`; `DictationTranscriber` offers a custom-LM content hint but finalizes poorly and is less accurate. v1 uses `SpeechTranscriber` with no recognition-layer vocabulary.
- Latency: streaming release→final measured at **0.22 s** on target hardware (file mode 0.37–0.44 s for a ~7 s utterance) — comfortably under the <1 s goal.
- Asset flow and the 16 kHz-vs-48 kHz format conversion both validated end-to-end.
