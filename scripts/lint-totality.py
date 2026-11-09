#!/usr/bin/env python3
"""Enforce the totality rules in STYLE.md mechanically.

STYLE.md forbids the partial functions listed in ``FORBIDDEN`` in library code.
Prose alone did not stop them being written, so this check turns a style rule
into a build failure.

A token only counts when it appears as code. String literals, character
literals, line comments and nested block comments are removed first, because
``"<head>"`` and ``"read-only"`` are prose, not calls. Test directories are
excluded: STYLE.md permits a partial helper in a test when failure produces a
clearer test failure.

Usage:
    scripts/lint-totality.py [path ...]

Exit status is 0 when clean and 1 when a forbidden token appears as code.
"""

from __future__ import annotations

import pathlib
import re
import sys

# (label, regex over comment-free and literal-free code)
#
# Each pattern demands a boundary before the token and rejects a preceding dot
# or apostrophe, so a qualified name, a primed name, and a longer identifier
# containing the token are all left alone.
def _word(token: str) -> str:
    return r"(?<![\w.'])" + token + r"(?![\w'])"


FORBIDDEN: list[tuple[str, str]] = [
    ("undefined", _word("undefined")),
    ("error (raise a typed failure instead)", _word("error")),
    ("errorWithoutStackTrace", _word("errorWithoutStackTrace")),
    ("head", _word("head")),
    ("tail", _word("tail")),
    ("init", _word("init")),
    ("last", _word("last")),
    ("(!!)", r"!!"),
    ("fromJust", _word("fromJust")),
    ("read (use a total parser instead)", _word("read")),
    ("unsafePerformIO", _word("unsafePerformIO")),
    ("unsafeCoerce", _word("unsafeCoerce")),
]

# Markers that only ever occur in a comment, so they are matched against the
# raw text. Stripping comments first would make this rule unreachable.
FORBIDDEN_ANYWHERE: list[tuple[str, str]] = [
    ("TODO, FIXME or XXX in library code", r"\b(?:TODO|FIXME|XXX)\b"),
]


def strip_noncode(text: str) -> str:
    """Blank out literals and comments, preserving line structure.

    Replaced characters become spaces rather than being deleted so that
    reported line and column numbers still refer to the real file.
    """
    out: list[str] = []
    i = 0
    n = len(text)
    depth = 0  # nesting depth of {- -}

    while i < n:
        ch = text[i]

        if depth > 0:
            if text.startswith("{-", i):
                depth += 1
                out.append("  ")
                i += 2
                continue
            if text.startswith("-}", i):
                depth -= 1
                out.append("  ")
                i += 2
                continue
            out.append("\n" if ch == "\n" else " ")
            i += 1
            continue

        if text.startswith("{-", i):
            depth = 1
            out.append("  ")
            i += 2
            continue

        # A line comment needs two or more dashes not followed by a symbol
        # character, otherwise operators such as --> and --| would be read as
        # comments. The symbol set is Haskell 2010's ascSymbol minus the dash.
        m = re.match(r"-{2,}(?![!#$%&*+./<=>?@\\^|~:])", text[i:])
        if m is not None:
            j = text.find("\n", i)
            if j == -1:
                j = n
            out.append(" " * (j - i))
            i = j
            continue

        if ch == '"':
            out.append(" ")
            i += 1
            while i < n:
                if text[i] == "\\" and i + 1 < n:
                    out.append("  ")
                    i += 2
                    continue
                if text[i] == '"':
                    out.append(" ")
                    i += 1
                    break
                out.append("\n" if text[i] == "\n" else " ")
                i += 1
            continue

        # A character literal, distinguished from a primed identifier by the
        # closing quote appearing where a literal would end.
        if ch == "'":
            m = re.match(r"'(?:\\[^']*|[^'\\])'", text[i:])
            if m is not None:
                out.append(" " * len(m.group(0)))
                i += len(m.group(0))
                continue

        out.append(ch)
        i += 1

    return "".join(out)


def check(path: pathlib.Path) -> list[str]:
    text = path.read_text(encoding="utf-8", errors="replace")
    code = strip_noncode(text)
    raw_lines = text.splitlines()
    code_lines = code.splitlines()
    findings: list[str] = []

    def record(line_number: int, column: int, label: str) -> None:
        original = raw_lines[line_number - 1] if line_number <= len(raw_lines) else ""
        findings.append(
            f"{path}:{line_number}:{column}: {label}\n    {original.strip()}"
        )

    for line_number, line in enumerate(code_lines, start=1):
        for label, pattern in FORBIDDEN:
            match = re.search(pattern, line)
            if match is not None:
                record(line_number, match.start() + 1, label)

    for line_number, line in enumerate(raw_lines, start=1):
        for label, pattern in FORBIDDEN_ANYWHERE:
            match = re.search(pattern, line)
            if match is not None:
                record(line_number, match.start() + 1, label)

    return findings


def main(argv: list[str]) -> int:
    repo_root = pathlib.Path(__file__).resolve().parent.parent
    roots = [pathlib.Path(a) for a in argv[1:]] or sorted(
        (repo_root / "packages").glob("*/src")
    )

    findings: list[str] = []
    files = 0
    for root in roots:
        for path in sorted(root.rglob("*.hs")):
            files += 1
            findings.extend(check(path))

    if findings:
        print(f"totality lint: {len(findings)} violation(s) in {files} file(s)\n")
        for finding in findings:
            print(finding)
        return 1

    print(f"totality lint: clean ({files} files)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
