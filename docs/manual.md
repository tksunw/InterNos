# Internos User Manual

*For Internos 2.0. Everything in this manual happens on your Mac. Nothing you say or type is sent anywhere.*

## What Internos is

Internos is a macOS menu bar utility for voice dictation. Hold a key, speak, release, and your words appear at the cursor in whatever app you're using. All speech recognition and text processing runs on your Mac using Apple's built-in frameworks. There is no cloud service, no account, and no network traffic in the dictation path.

Requirements: macOS 26 (Tahoe) or later, Apple Silicon. The optional AI features (smart cleanup and command mode) also need Apple Intelligence enabled in System Settings.

## Getting started

### Install

Download the DMG from the [releases page](https://github.com/tksunw/InterNos/releases), drag Internos to Applications, and launch it. Internos lives in the menu bar (a waveform-and-mic icon); it has no Dock icon.

**When updating**: replace the app in Applications, then quit and relaunch Internos. Replacing the file does not restart the running copy.

### Permissions

The setup window walks you through three macOS permissions. Each lives in its own System Settings pane, and Internos needs all three:

| Permission | Why Internos needs it |
|---|---|
| Microphone | Captures your voice while the dictation key is held |
| Input Monitoring | Detects the dictation key anywhere in macOS |
| Accessibility | Inserts the transcribed text at your cursor |

If Input Monitoring is granted while Internos is running, macOS requires an app restart before the key detection works. The setup window offers a Restart button for exactly this case.

### The speech model

On first run, Internos asks macOS to download the speech model for your language. This is a one-time system download, stored by macOS and shared across apps. Internos itself never talks to the network for this.

## Dictating

### Push to talk (default)

Hold **Right Option**, speak, release. The transcription is inserted at your cursor. A floating panel near the bottom of the screen shows a live waveform and your words as they're recognized.

### Toggle mode

In Settings, switch Activation to Toggle: tap the dictation key once to start, tap again to stop. Useful for longer dictation where holding a key is awkward.

### What the menu bar icon tells you

| Icon | Meaning |
|---|---|
| Waveform and mic | Idle, ready to dictate |
| Filled mic | Recording |
| Waveform | Transcribing |
| Warning triangle (brief) | Something went wrong with that utterance |
| Warning triangle (persistent) | Setup problem; open Setup & Permissions from the menu |
| Slashed waveform | Paused, or setup incomplete |

### When insertion is blocked

Internos never types into password fields (macOS Secure Input) and refuses to paste if you switch apps between releasing the key and the text landing. In both cases it plays the error sound and leaves the transcript on the clipboard so nothing is lost. You can also recover it from the menu (see [Last dictation recovery](#last-dictation-recovery)).

## Spoken commands

Say these while dictating. Commands are matched as whole phrases, so ordinary words like "bulletproof" or "newline" never trigger anything. Commands are English-only for now, regardless of the recognition language.

| You say | You get |
|---|---|
| "new line" | a line break |
| "new paragraph" | a blank line |
| "bullet point milk" | `• milk` (each one starts a new line) |
| "numbered item milk" | `1. milk` (numbering continues; a new paragraph resets to 1) |
| "open quote ... close quote" | curly quotes around the text |
| "open parenthesis ... close parenthesis" | parentheses around the text |
| "hashtag yard" | `#yard` |
| "emoji thumbs up" | 👍 |
| "at sign", "dollar sign", "percent sign" | `@`, `$`, `%` |
| "snippet calendar link" | your saved snippet, exactly as stored |
| "literal new line" | the words `new line` (escapes exactly one command) |

Emoji need the spoken word "emoji" before the name, so "she sent me a smiley face" stays literal text. About thirty names are supported; the full list is in the README.

## Personal dictionary (replacements)

The recognizer will never spell your project names, handles, or jargon correctly. Replacements fix that deterministically: you define a trigger phrase and the exact output, and Internos substitutes it after every transcription.

Examples: "cube control" becomes `kubectl`, "power shell" becomes `PowerShell`, "t k sun w" becomes `tksunw`.

Manage them in **Settings → Customizations → Replacements**. Matching is case-insensitive and whole-word ("cat" never fires inside "concatenate"), the longest trigger wins when triggers overlap, and the output is typed exactly as you wrote it. The output is never re-interpreted as a command or another replacement.

**Tip for spelled-out triggers**: the recognizer merges spoken letters unpredictably ("t k sun w" may arrive as "TK sun W" or "T. K. Sun W."). Internos compensates: any trigger containing single letters also matches on its squashed form, so all of those variants work. Just define the trigger the way you say it.

## Snippets

Snippets insert saved text by voice. Say "snippet" followed by the snippet's name:

> "snippet calendar link" → `https://example.com/schedule`

The "snippet" prefix is required, so saying a snippet's name in ordinary speech stays literal text. Content is inserted exactly as stored, line breaks and Unicode included, and is never altered by cleanup, replacements, or commands. Snippets are static text only; there are no variables or scripts.

Manage them in **Settings → Customizations → Snippets**. Names can be up to 100 characters, content up to 16 KB. Snippets are stored on your Mac as plain text, so don't put passwords or private keys in them.

Both replacements and snippets can be exported to a JSON file and imported on another Mac (Merge keeps existing entries on conflict; Replace swaps everything after validating the file).

## Smart cleanup

Cleanup tidies your dictation after recognition, entirely on-device via Apple Intelligence. Choose a level in **Settings → Processing**:

- **Off** (default): exactly what you said.
- **Light**: removes filler ("um", "uh"), accidental repetition, and false starts, and applies self-corrections. Say "meet Tuesday, actually Wednesday" and you get "meet Wednesday".
- **Polished**: Light, plus smoothing fragments into readable prose.

Rules that keep cleanup safe:

- Utterances containing snippets or spoken commands never go through the AI model. They get deterministic filler removal only ("um"/"uh"-class sounds), so the model can never invent text around your snippets.
- If the model is slow (over two seconds) or produces something suspicious, Internos falls back to your exact words plus filler removal. A cleanup failure never loses a dictation.
- Cleanup currently applies to English dictation only. Other languages are inserted exactly as recognized.
- Your original words are always recoverable: when cleanup changed the text, the menu shows **Copy Last Raw Dictation**.

Cleanup needs an Apple-Intelligence-eligible Mac. Without one, Light and Polished show as unavailable and dictation is unaffected.

## Command mode

Command mode rewrites text you've selected, using a spoken instruction. It works in any app that exposes its text to macOS accessibility.

1. Select text in any app.
2. Hold the **command key** (default Right Command; configurable in Settings).
3. Speak an instruction: "fix the spelling", "make this friendlier", "make this formal", "translate this to Spanish".
4. Release. The selection is replaced with the rewritten version.

The selection is read only at the moment you press the key, never in the background. If anything fails (no selection, model timeout, model refusal), your selection is left exactly as it was and the floating panel tells you why. After a rewrite, the original text is available under **Copy Last Raw Dictation** in the menu.

Command mode requires Apple Intelligence. If the command key is set to the same key as the dictation key, command mode is off; Settings shows a warning.

## Scratch that (voice undo)

Say **"scratch that"** as its own utterance to delete the previous dictation or command mode rewrite. Natural lead-ins work: "Actually, scratch that." and "No, scratch that." also trigger it. Longer sentences containing the phrase stay ordinary text.

It undoes one level (the most recent insertion), only while the same app is still in front. To use it: dictate, release the key, then hold the key again and say the phrase.

When dictating in another language, use the local phrase: Spanish "borra eso" or "tacha eso", French "efface ça", German "streich das" or "lösch das", Portuguese "apaga isso", Italian "cancella quello". English works everywhere as a fallback.

Note the difference from self-correction: fixing yourself mid-utterance ("...the grocery store, no scratch that, the pharmacy") is handled by smart cleanup (English only), not by the scratch command.

## Last dictation recovery

The menu bar menu keeps your most recent transcript available:

- **Copy Last Dictation**: puts the final text on the clipboard.
- **Paste Last Dictation**: inserts it again into the app you were just using, with the same safety checks as live dictation.
- **Copy Last Raw Dictation**: appears when cleanup or command mode changed the text; gives you the original.
- **Clear Last Dictation**: forgets it immediately.

This is held in memory only. It is never written to disk, and quitting Internos erases it. It is a recovery buffer, not a history; Internos deliberately keeps no transcript history.

## Languages

**Settings → General → Language** lists every language the on-device recognizer supports. Switching may trigger a one-time system download of that language's speech model.

What changes with a non-English language: recognition and the scratch phrase are localized; spoken commands (new line, snippet, emoji names) remain English; smart cleanup does not run (text is inserted exactly as recognized).

## Settings reference

### General

| Setting | What it does |
|---|---|
| Dictation key | The push-to-talk key. Right Option, Right Command, Right Control, or Fn/Globe |
| Activation | Push to talk (hold) or Toggle (tap to start/stop) |
| Command key | The command mode key. Must differ from the dictation key |
| Microphone | Which input device to record from |
| Language | Recognition language |
| Play sounds | Start/success/error sounds |
| Launch at login | Start Internos when you log in |
| Check for updates at launch | Off by default. When on, one request to GitHub at startup; this is the only automatic network call Internos can make |

### Processing

Smart cleanup level (Off, Light, Polished), Apple Intelligence availability, and a quick reference of the spoken commands.

### Customizations

Replacements and snippets: search, add, edit, enable or disable, delete, and Import/Export for moving your configuration between Macs. If the configuration file on disk is damaged or was written by a newer version of Internos, a notice appears here instead of silently overwriting your data.

## Troubleshooting

**Dictation key does nothing.** Check Input Monitoring in System Settings → Privacy & Security. If you granted it while Internos was running, restart Internos.

**Text doesn't insert, error sound plays.** Usually one of: a password field has focus (Secure Input; Internos refuses by design), you switched apps before the text landed, or Accessibility permission was revoked. In every case the transcript is on the clipboard and in the recovery menu.

**Command mode says "Select some text first" although text is selected.** The frontmost app doesn't expose its selection to macOS accessibility. Most native apps do; some Electron apps and browsers don't. Try it in TextEdit to confirm command mode itself works.

**Snippet or replacement doesn't fire.** Check it's enabled in Customizations, and say the name the way you defined it. For spelled-letter names, variants are matched automatically.

**Cleanup does nothing.** Check the level in Settings → Processing, that Apple Intelligence is enabled, and that the recognition language is English. Utterances containing snippets or commands intentionally get filler removal only.

**After an update, old bugs are still there.** Quit and relaunch: replacing the app in Applications does not restart the running copy. Check the version via the About panel.

## Privacy in one paragraph

Speech recognition, cleanup, and command mode all run on your Mac. Internos stores only your settings and customizations, never transcripts or audio. The last-dictation buffer lives in memory and dies with the process. Insertion prefers a direct accessibility path that bypasses the clipboard entirely; when an app forces the clipboard fallback, the transcript is briefly on the pasteboard where clipboard managers or Universal Clipboard could see it, as with any copied text. The only network call Internos can make is the optional update check. Full policy: [PRIVACY.md](../PRIVACY.md).
