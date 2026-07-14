# Privacy Policy

Internos is built on one premise: your voice is processed entirely on your Mac, and Internos never transmits your words anywhere.

## The short version

- All speech processing happens on-device, using Apple's Speech framework.
- Audio is never recorded to disk, transmitted, or retained. It exists only in memory during an utterance.
- Transcripts are never stored, logged, or transmitted by Internos. To insert text, the transcript briefly passes through the macOS general pasteboard (see "The clipboard" below), which other clipboard-aware software on your system can observe.
- There is no telemetry, no analytics, no crash reporting, no accounts, and no data collection of any kind.
- Internos makes zero network calls in the dictation path. You can verify this with Little Snitch or any packet monitor.

## What Internos stores

Configuration only:

- Settings (hotkey choice, activation mode, microphone selection, smart-cleanup mode, toggles) in the standard macOS preferences store (`UserDefaults`).
- Your personal dictionary and snippets in a local JSON file, `~/Library/Application Support/<bundle id>/customizations.json`, readable only by your user account. It contains what you typed into Settings — never transcripts, never audio, never model output. Export happens only when you choose Export and pick a location; nothing is placed in iCloud automatically.

Nothing else is persisted. In particular, the "last dictation" the menu offers to copy or paste again lives in process memory only: it is never written to disk or logs, and quitting Internos erases it.

## Smart cleanup (Apple Intelligence)

The optional smart-cleanup feature (off by default) uses Apple's Foundation Models framework — the on-device Apple Intelligence language model. When enabled, your transcribed text is processed by that model **on this Mac**: no network request, no cloud model, no fallback service, and Internos never logs the text sent to or returned from it. Snippet contents and personal-dictionary outputs are excluded from what the model sees. Internos does not read surrounding text, selected text, window titles, or clipboard contents to give the model context. Turning the feature off (or lacking an Apple-Intelligence-eligible Mac) changes nothing about dictation itself.

## Insertion and the clipboard

Internos inserts text directly into the focused field through the macOS Accessibility API whenever the target app supports it. On that path the transcript **never touches the clipboard** — nothing for Universal Clipboard or clipboard managers to see.

When an app doesn't support direct insertion, Internos falls back to a clipboard swap: it briefly places the transcript on the general pasteboard, pastes it, and restores your previous clipboard contents about a third of a second later (unless you copied something new in that window — a newer copy is never overwritten). While the transcript is on the pasteboard, it is visible to anything on your system that watches the clipboard: macOS features like Universal Clipboard may sync it to your other devices, and installed clipboard managers may record it. That is how the macOS pasteboard works and is outside Internos's control. Internos tags the entry with the standard `org.nspasteboard` transient and concealed marker types, which ask clipboard tools to skip or conceal it; well-behaved managers honor these markers, but they are a convention, not a guarantee.

## Command mode and selected text

Command mode rewrites text you have selected, using the same on-device Apple Intelligence model as smart cleanup. Internos reads your selected text **only at the moment you press the command key** — an explicit, deliberate invocation — and sends it, with your spoken instruction, to the on-device model. It is never read in the background, never used as ambient context for dictation, never logged, and never transmitted. If the rewrite fails for any reason, your selection is left untouched.

If a password field has focus (macOS Secure Input), Internos refuses to paste and instead leaves the transcript on the clipboard so it isn't lost. The same recovery applies when insertion is blocked for other reasons (for example, you switched apps before the paste landed, or Accessibility permission was revoked).

## The only network activity

Two cases, neither in the dictation path, neither carrying any of your data (smart cleanup, replacements, snippets, and commands all run locally and add no network activity):

1. **Speech model download.** On first run, macOS itself downloads Apple's on-device speech model from Apple's servers. This is a system asset, shared across apps, fetched by macOS — not by Internos.
2. **Update check.** If you click "Check for Updates…" (or enable the off-by-default "Check for updates at launch" setting), Internos makes one HTTPS request to the GitHub API to compare version numbers. The request contains no personal data, no identifiers, and nothing about your usage. With the setting off and the menu item unclicked, Internos makes no network requests at all.

## Permissions

Internos asks for three macOS permissions, used solely for the functions named: Microphone (capturing your voice while dictating), Input Monitoring (detecting the hotkey), and Accessibility (inserting text at your cursor). None of these are used for anything else.

## Changes

If any of the above ever changes, this document changes with it, in the same commit. The source is public; the policy is verifiable against the code at any time.
