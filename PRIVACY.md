# Privacy Policy

Internos is built on one premise: your voice and your words never leave your Mac.

## The short version

- All speech processing happens on-device, using Apple's Speech framework.
- Audio is never recorded to disk, transmitted, or retained. It exists only in memory during an utterance.
- Transcripts are never stored, logged, or transmitted. They go to the app you're typing into and nowhere else.
- There is no telemetry, no analytics, no crash reporting, no accounts, and no data collection of any kind.
- Internos makes zero network calls in the dictation path. You can verify this with Little Snitch or any packet monitor.

## What Internos stores

Settings only: your hotkey choice, activation mode, microphone selection, and toggles. These live in the standard macOS preferences store (`UserDefaults`) on your Mac. Nothing else is persisted.

## The clipboard

To insert text at your cursor, Internos briefly places the transcript on the clipboard, pastes it, and restores your previous clipboard contents about a third of a second later. If a password field has focus (macOS Secure Input), Internos refuses to paste and instead leaves the transcript on the clipboard so it isn't lost — be aware that clipboard managers or Universal Clipboard may see it there, as they would any copied text.

## The only network activity

Two cases, neither in the dictation path, neither carrying any of your data:

1. **Speech model download.** On first run, macOS itself downloads Apple's on-device speech model from Apple's servers. This is a system asset, shared across apps, fetched by macOS — not by Internos.
2. **Update check.** If you click "Check for Updates…" (or enable the off-by-default "Check for updates at launch" setting), Internos makes one HTTPS request to the GitHub API to compare version numbers. The request contains no personal data, no identifiers, and nothing about your usage. With the setting off and the menu item unclicked, Internos makes no network requests at all.

## Permissions

Internos asks for three macOS permissions, used solely for the functions named: Microphone (capturing your voice while dictating), Input Monitoring (detecting the hotkey), and Accessibility (inserting text at your cursor). None of these are used for anything else.

## Changes

If any of the above ever changes, this document changes with it, in the same commit. The source is public; the policy is verifiable against the code at any time.
