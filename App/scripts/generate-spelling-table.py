#!/usr/bin/env python3
"""Generate App/Sources/SpellingTable.generated.swift from VarCon.

Usage:
  scripts/generate-spelling-table.py [--max-level 80] [--varcon PATH] [--out PATH]
  scripts/generate-spelling-table.py --self-test

Reads App/Data/varcon/varcon.txt (SCOWL's Variant Conversion Info) and writes one
compact "source<TAB>target" table per spelling convention. Run by hand; commit
the output. Counts and the words dropped as ambiguous go to stderr.

Rules (docs/specs/spelling-convention.md, "Generator"):
  1. Skip clusters above --max-level, "_" (non-regional) groups, words tagged
     "x" (improper) for any category, and any word with an uppercase letter, a
     space or a non-ASCII character (proper nouns, phrases and loan words are not
     single-token spelling variants).
  2. On a line, after the implication rules (B implies Z, Z implies C, B implies
     D, each only when the line has no tag of that category), the convention's
     preferred spellings are those tagged with the bare letter. Exactly one
     preferred word on the line makes every other word a candidate source.
  3. A source maps to a target only if every line it appears on yields the same
     target and it is never itself preferred on any line.
  4. Identity pairs are dropped.
"""

import argparse
import re
import sys
from collections import defaultdict
from pathlib import Path

CONVENTIONS = [  # (VarCon tag, Swift property name)
    ("A", "american"),
    ("B", "british"),
    ("Z", "oxford"),
    ("C", "canadian"),
    ("D", "australian"),
]
CATEGORY_LETTERS = "ABZCD_"
HEADER_RE = re.compile(r"^#.*\(level (\d+)\)")
TAG_RE = re.compile(r"^([ABZCD_])([.vVx-]?)$")

SELF_TEST_EXCERPT = """\
# color <verified> (level 35)
A Cv DV: color / B C D: colour
# organize (level 35)
A Z: organize / B: organise
# center (level 35)
A Cv: center / B C: centre
# check (level 35)
A CV: check / B C: cheque | <N> bank
A B: check | <N> verify
# program (level 35)
A C D 1: program / B Dv 2: programme | <N>
A B 1: program / AV BV 2: programme | <V>
A B 1: program | computer program
# meter (level 35)
A B: meter | measuring device
A Cv: meter / AV B C: metre | <N> metric meter, rhythmic pattern
# tire (level 35)
A B: tire | exhausted
A C: tire / B: tyre | wheel
# story (level 35)
A B: story | book
A Cv DV: story / AV B C D: storey | level of building
# curb (level 35)
A B: curb | restrain
A C: curb / B: kerb | street edge
# jail (level 35)
A B Z: jail / Bv ZV: gaol
# labor (level 35)
A Cv DV: labor / B C D: labour
# abnormalize (level 95)
A Z: abnormalize / B: abnormalise
"""


def parse_groups(line):
    """One VarCon line -> list of (tags, word). tags: {letter: suffix}."""
    body = line.split("|", 1)[0].split("#", 1)[0].strip()
    groups = []
    for chunk in body.split(" / "):
        if ":" not in chunk:
            continue
        tag_text, word = chunk.split(":", 1)
        tags = {}
        for token in tag_text.split():
            m = TAG_RE.match(token)
            if m:  # anything else is a sense number ("1", "2"), skipped
                tags[m.group(1)] = m.group(2)
        groups.append((tags, word.strip()))
    return groups


def apply_implications(groups):
    """B implies Z, Z implies C, B implies D, each only when the line has no such tag."""
    def present(letter):
        return any(letter in tags for tags, _ in groups)

    for source, derived in (("B", "Z"), ("Z", "C"), ("B", "D")):
        if present(derived):
            continue
        for tags, _ in groups:
            if source in tags:
                tags[derived] = tags[source]


def build_tables(text, max_level):
    """Return ({letter: {source: target}}, stats)."""
    candidates = {c: defaultdict(set) for c, _ in CONVENTIONS}  # source -> {target}
    preferred = {c: set() for c, _ in CONVENTIONS}
    level = 0
    skipped_words = 0
    for raw in text.splitlines():
        if not raw.strip():
            continue
        if raw.startswith("#"):
            m = HEADER_RE.match(raw)
            if m:
                level = int(m.group(1))
            continue
        if level > max_level:
            continue
        groups = parse_groups(raw)
        apply_implications(groups)
        usable = []
        for tags, word in groups:
            if "_" in tags and len(tags) == 1:
                continue
            if "x" in tags.values() or word != word.lower() or " " in word or not word.isascii():
                skipped_words += 1
                continue
            usable.append((tags, word))
        for letter, _ in CONVENTIONS:
            pref = [w for tags, w in usable if tags.get(letter) == ""]
            preferred[letter].update(pref)
            if len(pref) != 1:
                continue
            target = pref[0]
            for _, w in usable:
                if w != target:
                    candidates[letter][w].add(target)

    tables = {}
    dropped = {}
    for letter, _ in CONVENTIONS:
        table = {}
        drop = []
        for source, targets in candidates[letter].items():
            if len(targets) == 1 and source not in preferred[letter]:
                table[source] = next(iter(targets))
            else:
                drop.append(source)
        tables[letter] = table
        dropped[letter] = sorted(drop)
    return tables, {"dropped": dropped, "skipped_words": skipped_words}


def read_varcon(path):
    """The 2020.12.07 file is UTF-8 apart from a stray Latin-1 byte."""
    data = path.read_bytes()
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError:
        return data.decode("latin-1")


def render_swift(tables, version, command):
    lines = [
        "// Generated file. Do not edit.",
        f"// Source: App/Data/varcon/varcon.txt (VarCon {version}, SCOWL), see its README for the license.",
        f"// Regenerate: {command}",
        "//",
        "// One `source\\ttarget` line per entry, lowercase; `SpellingNormalizer` parses",
        "// a convention's table on first use. A string literal keeps compile time flat",
        "// where a dictionary literal of this size does not.",
        "",
        "enum SpellingTable {",
    ]
    for letter, name in CONVENTIONS:
        table = tables[letter]
        lines.append(f"    /// {len(table)} entries.")
        lines.append(f'    static let {name} = """')
        for source in sorted(table):
            lines.append(f"{source}\t{table[source]}")
        lines.append('"""')
        lines.append("")
    lines.append("}")
    return "\n".join(lines) + "\n"


def self_test():
    tables, _ = build_tables(SELF_TEST_EXCERPT, max_level=80)
    A, B, Z, C, D = (tables[c] for c, _ in CONVENTIONS)
    expect_american = {
        "colour": "color", "organise": "organize", "centre": "center", "cheque": "check",
        "programme": "program", "metre": "meter", "tyre": "tire", "storey": "story",
        "kerb": "curb", "gaol": "jail", "labour": "labor",
    }
    assert A == expect_american, A
    assert B == {"color": "colour", "organize": "organise", "center": "centre", "labor": "labour",
                 "gaol": "jail"}, B
    for ambiguous in ("check", "program", "meter", "story", "tire", "curb"):
        assert ambiguous not in B, ambiguous
    assert Z["organise"] == "organize" and Z["color"] == "colour", Z
    assert D["programme"] == "program" and "program" not in D, D
    assert D["color"] == "colour" and "tire" not in D, D  # tire is also the Australian "exhausted"
    assert all(t.get("gaol") == "jail" for t in (A, B, Z, C, D))
    assert C["color"] == "colour" and C["center"] == "centre", C
    assert C["organise"] == "organize" and C["tyre"] == "tire", C
    assert "abnormalise" not in A, "level ceiling not applied"
    print("self-test ok", file=sys.stderr)


def main():
    root = Path(__file__).resolve().parents[1]
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--max-level", type=int, default=80, help="skip SCOWL clusters above this level (default 80)")
    ap.add_argument("--varcon", type=Path, default=root / "Data/varcon/varcon.txt")
    ap.add_argument("--readme", type=Path, default=root / "Data/varcon/README")
    ap.add_argument("--out", type=Path, default=root / "Sources/SpellingTable.generated.swift")
    ap.add_argument("--self-test", action="store_true", help="check the rules against the spec excerpt and exit")
    args = ap.parse_args()

    if args.self_test:
        self_test()
        return

    version = "unknown"
    m = re.search(r"^Version (\S+)", args.readme.read_text(encoding="utf-8"), re.M)
    if m:
        version = m.group(1)
    tables, stats = build_tables(read_varcon(args.varcon), args.max_level)
    command = f"App/scripts/generate-spelling-table.py --max-level {args.max_level}"
    args.out.write_text(render_swift(tables, version, command), encoding="utf-8")

    print(f"skipped words (improper, uppercase, phrase, non-ASCII): {stats['skipped_words']}", file=sys.stderr)
    for letter, name in CONVENTIONS:
        drop = stats["dropped"][letter]
        print(f"{name}: {len(tables[letter])} entries, {len(drop)} dropped as ambiguous", file=sys.stderr)
        print("  " + " ".join(drop), file=sys.stderr)
    print(f"wrote {args.out}", file=sys.stderr)


if __name__ == "__main__":
    main()
