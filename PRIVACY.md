# Privacy Policy

Internos is built on one premise: your voice is processed entirely on your Mac, and Internos never transmits your words anywhere.

## The short version

- All speech processing happens on-device, using Apple's Speech framework.
- Audio is never recorded to disk, transmitted, or retained. It exists only in memory during an utterance.
- Transcripts are never stored, logged, or transmitted by Internos. To insert text, the transcript briefly passes through the macOS general pasteboard (see "The clipboard" below), which other clipboard-aware software on your system can observe.
- There is no telemetry, no analytics, no crash reporting, no accounts, and no data collection of any kind.
- Internos makes zero network calls in the dictation path. You can verify this with Little Snitch or any packet monitor.

## What Internos stores

Settings only: your hotkey choice, activation mode, microphone selection, and toggles. These live in the standard macOS preferences store (`UserDefaults`) on your Mac. Nothing else is persisted.

## The clipboard

To insert text at your cursor, Internos briefly places the transcript on the general pasteboard, pastes it, and restores your previous clipboard contents about a third of a second later (unless you copied something new in that window — a newer copy is never overwritten). While the transcript is on the pasteboard, it is visible to anything on your system that watches the clipboard: macOS features like Universal Clipboard may sync it to your other devices, and installed clipboard managers may record it. That is how the macOS pasteboard works and is outside Internos's control. Internos tags the entry with the standard `org.nspasteboard` transient and concealed marker types, which ask clipboard tools to skip or conceal it; well-behaved managers honor these markers, but they are a convention, not a guarantee.

If a password field has focus (macOS Secure Input), Internos refuses to paste and instead leaves the transcript on the clipboard so it isn't lost. The same recovery applies when insertion is blocked for other reasons (for example, you switched apps before the paste landed, or Accessibility permission was revoked).

## The only network activity

Two cases, neither in the dictation path, neither carrying any of your data:

1. **Speech model download.** On first run, macOS itself downloads Apple's on-device speech model from Apple's servers. This is a system asset, shared across apps, fetched by macOS — not by Internos.
2. **Update check.** If you click "Check for Updates…" (or enable the off-by-default "Check for updates at launch" setting), Internos makes one HTTPS request to the GitHub API to compare version numbers. The request contains no personal data, no identifiers, and nothing about your usage. With the setting off and the menu item unclicked, Internos makes no network requests at all.

## Permissions

Internos asks for three macOS permissions, used solely for the functions named: Microphone (capturing your voice while dictating), Input Monitoring (detecting the hotkey), and Accessibility (inserting text at your cursor). None of these are used for anything else.

## Changes

If any of the above ever changes, this document changes with it, in the same commit. The source is public; the policy is verifiable against the code at any time.
