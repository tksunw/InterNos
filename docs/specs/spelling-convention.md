# Spelling convention: spec

Status: approved design, not yet built. Written 2026-11-01 for the agent that
implements it. Read `CLAUDE.md` first; this document assumes it.

## Problem

Apple's `SpeechTranscriber` ships one model per locale, and each model writes
that locale's spelling. A speaker whose accent fits en_AU or en_GB better than
en_US gets a more accurate transcript by switching, and then gets "colour" and
"organise" in text they want written the American way. Field case: an
Australian living in the US. The same problem will exist for any future
non-Apple engine (Whisper, Parakeet), none of which has a spelling knob at all.

Recognition language and written spelling are separate choices. Today they are
one setting. This spec splits them.

## What the user sees

Two pickers in Settings, side by side under the existing Language section
(`SettingsView.swift`, the `Section` holding the `Picker("Language", ...)`).

Language: unchanged. Picks the recognition locale, which today selects the
Apple model. A future engine picker joins this group as a third control and
does not touch anything below.

Spelling: a new picker with these options, in this order.

- As recognized (default)
- American
- British
- British (Oxford)
- Canadian
- Australian

Behaviour:

- "As recognized" is a no-op. It is the default because the trust posture is
  verbatim unless asked (see the Cleanup default decision in `CLAUDE.md`).
- The picker is disabled, and its footer reads "English only", when the
  recognition locale does not start with `en`. The setting is kept, not reset,
  so switching back to an English locale restores it. Mirror
  `CleanupMode.effective(forLocaleIdentifier:)` in `CleanupMode.swift`, which
  gates cleanup the same way.
- Changing it applies to the next dictation. Nothing already inserted is
  touched.

Footer text under the picker, roughly: "Writes English with the chosen
country's spelling, whatever the recognition language's model produced.
Personal-dictionary outputs and snippets are never changed."

## Setting

`AppSettings.swift`: a new enum and property.

```swift
enum SpellingConvention: String, CaseIterable, Identifiable {
    case asRecognized, american, british, oxford, canadian, australian
    var id: String { rawValue }
    var label: String { ... }          // the picker strings above
    /// Spelling is an English feature; every other locale is a no-op.
    func effective(forLocaleIdentifier identifier: String) -> SpellingConvention {
        identifier.lowercased().hasPrefix("en") ? self : .asRecognized
    }
}
```

Key: `spellingConvention`, stored as the raw string, default `asRecognized`.
The Settings picker binds with `@AppStorage` the way `cleanupModeKey` does,
so declare the key and default as top-level constants next to
`cleanupModeKey`, not inside `AppSettings.Key`. `AppSettings.spellingConvention`
reads and writes the same key.

## Pipeline position

`TranscriptPipeline.process` (in `TranscriptPipeline.swift`) runs:

```
command parser → [smart cleanup or filler strip] → user replacements → renderer
```

The normalizer becomes a stage between cleanup and replacements, applied to
every `.text` segment and nothing else:

```
command parser → [cleanup] → spelling → user replacements → renderer
```

Why there:

- After cleanup, because cleanup is a language model and can emit either
  spelling. Normalizing after it makes the setting authoritative over the model.
- Before replacements, because replacement outputs become protected
  `.replacement` segments and the user's exact text must never be re-spelled.
  The same holds for `.literal` and `.snippet`: the normalizer only ever sees
  `.text`.

`ProcessingSettings` gains `var spelling: SpellingConvention = .asRecognized`.
`CustomizationStore.processingSnapshot(cleanupMode:)` grows a `spelling:`
parameter; its one call site is `DictationController.swift` near line 146, where
the cleanup mode is read from `AppSettings.shared`. Read the spelling setting
there the same way and apply `.effective(forLocaleIdentifier:)` where
`DictationController` already applies the cleanup equivalent (near line 551),
so both features gate on the same locale decision.

### Replacement triggers

Replacements run on normalized text, so a trigger typed as "colour" would stop
firing once American is selected. Avoid the surprise: `ReplacementMatcher.init`
takes the active `SpellingNormalizer` and normalizes each trigger's words
(`TriggerWord.core`) with it before building `byFirstWord` and the compact keys.
Outputs are untouched. `CustomizationStore.rebuildMatchStructures` therefore
needs the spelling setting too, and the matcher must be rebuilt when the
setting changes, not only when rules change. `SnippetTable` names are matched
by the command parser on raw text before this stage and are left alone.

### Live preview

The preview (`onPartial` in `DictationController`) shows raw recognizer text.
Applying the normalizer there is cheap and deterministic, but it is display
only and not required for 1.0 of this feature. If done, run it on the whole
partial string with sentence context unknown, which means the proper-noun rule
below treats only the very first word as sentence-initial.

### Command mode

`CommandTransformer` output is a rewrite of the user's selection and is not
dictation; leave it alone in this change. Note it in the manual.

## The normalizer

New file `App/Sources/SpellingNormalizer.swift`.

```swift
struct SpellingNormalizer: Sendable {
    static let none = SpellingNormalizer(convention: .asRecognized)
    init(convention: SpellingConvention)
    /// Rewrites ordinary text. Returns the input unchanged for .asRecognized.
    func normalize(_ text: String, startsSentence: Bool) -> String
    /// Single-word lookup used for replacement triggers; folded input, folded output.
    func normalizedCore(_ core: String) -> String
}
```

Tokenize with `TranscriptTokenizer.tokenize` (`TranscriptCommandParser.swift`)
so word boundaries and punctuation handling match every other stage. For each
token:

1. Look up `token.core` (already case-folded, punctuation stripped; an internal
   apostrophe stays, so "colour's" is one lookup and the table carries the
   possessive forms VarCon lists).
2. No hit and the core contains a hyphen: split on hyphens, look up each part,
   rejoin. "colour-blind" converts; "e-mail" does not.
3. Case: reproduce the original token's pattern on the replacement. All lower
   stays lower. Initial capital gives an initial capital. All caps is skipped
   entirely (acronym risk, and no dictation emits "COLOUR" by accident).
4. Proper-noun rule: a token with an initial capital is converted only when it
   is sentence-initial: the first token when `startsSentence` is true, or the
   token after one whose `trailing` contains a `TranscriptTokenizer.sentenceEnders`
   character. "Centrelink" and "Harbour Bridge" survive; "Labor won" at the
   start of a sentence becomes "Labour won" under a British target. That is the
   accepted cost and the manual says so.
5. Splice replacements back using `token.range` so whitespace and punctuation
   outside the word are byte-for-byte preserved.

`startsSentence` for a segment is computed in the pipeline the same way
`endsSentence` is today, by looking at the previous non-mark segment: `nil`,
`.lineBreak`, `.paragraphBreak`, `.bulletItem`, `.numberedItem` mean true.

Tables are built lazily per convention on first use and cached in a static;
lookups are dictionary hits. Add a case to `PipelinePerformanceTests` with a
long paragraph and the British target.

## Data

Source: VarCon (Variant Conversion Info) from SCOWL, `varcon.txt`, by Kevin
Atkinson and Benjamin Titze. Fetch from
`https://raw.githubusercontent.com/en-wl/wordlist/master/varcon/varcon.txt`
(`wordlist.aspell.net` was unreachable from the drafting environment; the
GitHub mirror is the project's own). Vendor it with its `README` under
`App/Data/varcon/` so the build is reproducible offline. The license is the
"Copyright" section at the end of that README (from line 526 in the 2020.12.07
release): a permissive notice-and-disclaimer grant from Kevin Atkinson and
Benjamin Titze, plus the Ispell notice from Geoff Kuenning with its BSD-style
no-endorsement clause. Reproduce that section verbatim in the About panel's
credits and in `README.md`; the BSD clause requires it.

### Format, as needed here

Each cluster starts with `# headword <verified> (level N)`. Each line is a
group of spellings of one word: `TAGS: word / TAGS: word ...`, optionally
followed by ` | usage` (a definition, `:n`, or a POS tag like `<N>`), with `#`
comments after that. Tag letters:

| Tag | Category |
|---|---|
| `A` | American |
| `B` | British, -ise |
| `Z` | British, -ize (Oxford) |
| `C` | Canadian |
| `D` | Australian |
| `_` | Other, not regional, ignore |

Each letter may carry a variant suffix: none means preferred; `.` equal; `v`
variant; `V` seldom; `-` possible, avoid; `x` improper. Implication rules when a
line lacks a category: `B` implies `Z`, `Z` implies `C`, `B` implies `D`.

Verified line shapes from the file, which the generator's tests should use:

```
A Cv DV: color / B C D: colour
A Z: organize / B: organise
A Cv: center / B C: centre
A CV: check / B C: cheque | <N> bank
A B: check | <N> verify
A C D 1: program / B Dv 2: programme | <N>
A B 1: program / AV BV 2: programme | <V>
A B 1: program | computer program
A B: meter | measuring device
A Cv: meter / AV B C: metre | <N> metric meter, rhythmic pattern
A B: tire | exhausted
A C: tire / B: tyre | wheel
A B: story | book
A Cv DV: story / AV B C D: storey | level of building
A B: curb | restrain
A C: curb / B: kerb | street edge
A B Z: jail / Bv ZV: gaol
A Cv DV: labor / B C D: labour
```

### Generator

`App/scripts/generate-spelling-table.py`, Python 3 standard library only, run
by hand and the output committed. It writes
`App/Sources/SpellingTable.generated.swift`: one `enum SpellingTable` holding a
`static let` string per convention in a compact `source\ttarget\n` form that
the normalizer parses on first use. A string literal compiles in seconds; a
Swift dictionary literal with thousands of entries does not, and a resource
bundle would need `Package.swift` resources plus a copy step in `make-app.sh`
that does not exist today. The header comment names the VarCon version and
the generator command.

Rules, for target convention X in {A, B, Z, C, D}:

1. Skip clusters above SCOWL level 80 (the `(level N)` on the cluster header);
   make the ceiling a script flag. Skip `_` lines. Skip words tagged `x` for
   any category.
2. On each line, after applying the implication rules, the X-preferred
   spellings are those tagged with bare `X`. If a line has exactly one, every
   other spelling on that line is a candidate source for it. If it has none or
   more than one, the line contributes nothing for X.
3. A source word maps to a target only if it is unambiguous across the whole
   file: every line it appears on yields the same target for X, and it is never
   itself X-preferred on any line. This is the rule that keeps British targets
   from rewriting "check", "program", "meter", "story", "tire" and "curb", each
   of which is a different word in British English on at least one line. For
   the American target the same rule produces a near-complete map, because
   American English merged those pairs.
4. Drop identity pairs. Emit lowercase only; VarCon is lowercase.
5. Print counts per convention and the dropped-as-ambiguous list to stderr so a
   reviewer can eyeball it.

Expected shape from the above lines: American gets colour, organise, centre,
cheque, programme, metre, tyre, storey, kerb, gaol and labour. British gets
color, organize, center and labor, and not check, program, meter, story, tire
or curb. Oxford is British with -ize. Australian equals British where VarCon
has no `D` tag; where it has one it differs, so Australian maps programme to
program on every line while British leaves program alone. Gaol maps to jail
for every target. Canadian keeps colour and centre but gets organize and tire.

## Tests

`App/Tests/SpellingNormalizerTests.swift`, deterministic, no model:

- Each pair in the expected-shape paragraph above, for the convention named.
- Ambiguous British words unchanged: "I'll check the program's meter" under
  British is identical.
- Case patterns: "colour", "Colour" sentence-initial, "COLOUR" skipped.
- Proper nouns: "I crossed the Harbour Bridge" under American keeps "Harbour".
  "Harbour views are nice." converts the first word.
- Possessive and hyphen: "the colour's depth", "colour-blind".
- Punctuation and whitespace outside words preserved exactly, including
  double spaces and a trailing newline.
- `.asRecognized` returns the input object unchanged for any locale.
- Non-English locale: `.british.effective(forLocaleIdentifier: "es_ES")` is
  `.asRecognized`.
- Pipeline: a `.replacement` output and a snippet body containing "colour" are
  untouched under American; the surrounding `.text` converts.
- Pipeline: a replacement rule triggered on "colour" still fires on dictated
  "colour" under American, and its output is inserted as typed.
- Pipeline: cleanup fake returns British text, American setting converts it
  (cleanup runs first).
- Generator: a Python unit test or a Swift test over a vendored excerpt of the
  lines listed above, asserting the ambiguity rule's output. Pick whichever the
  repo can run in CI; today that is `swift test`, so a Swift test over the
  committed table is the practical choice, with the excerpt check living in
  the Python script's `--self-test` flag.

Run the full suite; `PipelinePerformanceTests` must still pass with the new
stage enabled.

## Docs and release

- `CHANGELOG.md`: an Added entry under `[Unreleased]`.
- `docs/manual.md`: a paragraph in "Languages" and a row in "Settings
  reference". Say that proper nouns mid-sentence are left alone, that a
  sentence-initial proper noun can be converted, and that command mode is not
  affected.
- `PRIVACY.md`: no change in substance. The table is in the binary; there is
  no network and no new file. Add VarCon to the attribution list if PRIVACY.md
  carries one; otherwise README and About.
- `Internos-PRD.md`: a one-line note that custom vocabulary remains a
  post-processing pass and spelling convention is the first such pass.

## Out of scope, noted for later

- Vocabulary conversion (VarCon's `voc.tab`: lift vs elevator). Not spelling,
  not safe to automate, not wanted.
- Converting command-mode rewrites.
- A phonetic fuzzy tier for personal-dictionary triggers (Levenshtein plus
  Soundex, as Handy does in `audio_toolkit/text.rs`). Separate spec.
- An alternate recognition engine. The Spelling picker is designed so that
  adding an engine picker changes nothing here.
