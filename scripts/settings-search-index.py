#!/usr/bin/env python3
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
"""Builds Settings search's catalog (apps/browser/Sources/Airc/Settings/SettingsSearchCatalog.swift).

It reads the Settings panes from their Swift sources: SettingsWindow's `page` switch names each pane's view, and every
SettingsSection(title:help:), SettingsRow(title:subtitle:) and AircToggleRow(_:subtitle:) reached from that view (through
the structs it calls) becomes an entry, with its pane and section, in the order the pane shows them. Titles that aren't
literals (a Space's or profile's name) are left out; the app adds the Shortcuts pane's commands itself at runtime.

  scripts/settings-search-index.py           rewrite the catalog
  scripts/settings-search-index.py --check   exit 1 if the catalog is out of date (and say what changed)
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "apps/browser/Sources/Airc")
OUT = os.path.join(SRC, "Settings/SettingsSearchCatalog.swift")
SKIP_DIRS = {"Debug"}


# --- A small Swift lexer: identifiers, string literals (raw text kept), punctuation. Comments dropped. ---

class Tok:
    __slots__ = ("kind", "text", "interp")

    def __init__(self, kind, text, interp=False):
        self.kind, self.text, self.interp = kind, text, interp

    def __repr__(self):
        return f"{self.kind}:{self.text!r}"


def lex(src):
    toks, i, n = [], 0, len(src)
    while i < n:
        c = src[i]
        if c in " \t\r\n":
            i += 1
        elif src.startswith("//", i):
            j = src.find("\n", i)
            i = n if j < 0 else j
        elif src.startswith("/*", i):
            depth, i = 1, i + 2
            while i < n and depth:
                if src.startswith("/*", i):
                    depth, i = depth + 1, i + 2
                elif src.startswith("*/", i):
                    depth, i = depth - 1, i + 2
                else:
                    i += 1
        elif c == '"' or (c == "#" and i + 1 < n and src[i + 1] == '"'):
            i, tok = lex_string(src, i)
            toks.append(tok)
        elif c.isalpha() or c == "_":
            j = i
            while j < n and (src[j].isalnum() or src[j] == "_"):
                j += 1
            toks.append(Tok("id", src[i:j]))
            i = j
        elif c.isdigit():
            j = i
            while j < n and (src[j].isalnum() or src[j] in "._"):
                j += 1
            toks.append(Tok("num", src[i:j]))
            i = j
        else:
            toks.append(Tok("p", c))
            i += 1
    return toks


def lex_string(src, i):
    """A string literal at i (plain, multi-line or #raw#). Returns (end, Tok) with the literal's content as written."""
    hashes = 0
    while src[i] == "#":
        hashes, i = hashes + 1, i + 1
    multi = src.startswith('"""', i)
    quote = '"""' if multi else '"'
    i += len(quote)
    close = quote + "#" * hashes
    start, interp, n = i, False, len(src)
    while i < n:
        if src[i] == "\\" and src.startswith("#" * hashes, i + 1):
            k = i + 1 + hashes
            if k < n and src[k] == "(":
                interp, depth, i = True, 1, k + 1
                while i < n and depth:   # skip the interpolation, strings and parens inside it
                    if src[i] == '"':
                        i, _ = lex_string(src, i)
                        continue
                    depth += {"(": 1, ")": -1}.get(src[i], 0)
                    i += 1
                continue
            i = k + 1
            continue
        if src.startswith(close, i):
            text = src[start:i]
            return i + len(close), Tok("s", text.strip("\n") if multi else text, interp or multi or hashes > 0)
        i += 1
    raise ValueError("unterminated string")


def match(toks, i, open_, close):
    """Index of the token closing the bracket at i."""
    depth = 0
    for j in range(i, len(toks)):
        t = toks[j]
        if t.kind == "p" and t.text == open_:
            depth += 1
        elif t.kind == "p" and t.text == close:
            depth -= 1
            if depth == 0:
                return j
    raise ValueError("unbalanced")


# --- Structs and their bodies ---

def structs(files):
    """name -> (tokens, body_start, body_end) for every struct (View or not) in the sources."""
    out = {}
    for toks in files:
        for i, t in enumerate(toks):
            if t.kind == "id" and t.text == "struct" and i + 1 < len(toks) and toks[i + 1].kind == "id":
                j = i + 2
                while j < len(toks) and not (toks[j].kind == "p" and toks[j].text == "{"):
                    j += 1
                if j < len(toks):
                    out.setdefault(toks[i + 1].text, (toks, j, match(toks, j, "{", "}")))
    return out


def args(toks, i):
    """The call's arguments: [(label or None, [tokens])], for the '(' at i; and the index of its ')'."""
    end = match(toks, i, "(", ")")
    out, cur, depth, j = [], [], 0, i + 1
    while j < end:
        t = toks[j]
        if t.kind == "p" and t.text in "([{":
            depth += 1
        elif t.kind == "p" and t.text in ")]}":
            depth -= 1
        if depth == 0 and t.kind == "p" and t.text == ",":
            out.append(cur)
            cur = []
        else:
            cur.append(t)
        j += 1
    if cur:
        out.append(cur)
    labelled = []
    for a in out:
        if len(a) >= 2 and a[0].kind == "id" and a[1].kind == "p" and a[1].text == ":":
            labelled.append((a[0].text, a[2:]))
        else:
            labelled.append((None, a))
    return labelled, end


def literals(expr):
    """Literal strings an expression can be: "a"; "a" + "b"; c ? "a" : "b" (both). [] for anything else."""
    if not expr:
        return []
    if all(t.kind == "s" and not t.interp or (t.kind == "p" and t.text == "+") for t in expr):
        parts = [t.text for t in expr if t.kind == "s"]
        return ["".join(parts)] if parts else []
    q = [k for k, t in enumerate(expr) if t.kind == "p" and t.text == "?"]
    c = [k for k, t in enumerate(expr) if t.kind == "p" and t.text == ":"]
    if len(q) == 1 and len(c) == 1 and q[0] < c[0]:
        a, b = expr[q[0] + 1:c[0]], expr[c[0] + 1:]
        if len(a) == 1 and len(b) == 1 and a[0].kind == "s" and b[0].kind == "s" and not a[0].interp and not b[0].interp:
            return [a[0].text, b[0].text]
    return []


def arg(labelled, label):
    for l, e in labelled:
        if l == label:
            return e
    return None


class Walker:
    def __init__(self, table):
        self.table = table
        self.entries = []
        self.stack = []

    def walk_struct(self, page, name, section):
        if name in self.stack:
            return
        self.stack.append(name)
        toks, a, b = self.table[name]
        self.walk(page, toks, a + 1, b, section)
        self.stack.pop()

    def walk(self, page, toks, a, b, section):
        i = a
        while i < b:
            t = toks[i]
            nxt = toks[i + 1] if i + 1 < b else None
            called = t.kind == "id" and nxt is not None and nxt.kind == "p" and nxt.text == "("
            if called and t.text == "SettingsSection":
                labelled, end = args(toks, i + 1)
                titles = literals(arg(labelled, "title"))
                help_ = literals(arg(labelled, "help"))
                inner = section
                if titles:
                    inner = titles[0]
                    self.add(page, "section", titles[0], None, help_[0] if help_ else None, titles[1:])
                j = end + 1
                if j < b and toks[j].kind == "p" and toks[j].text == "{":
                    close = match(toks, j, "{", "}")
                    self.walk(page, toks, j + 1, close, inner)
                    i = close + 1
                else:
                    i = j
                continue
            if called and t.text in ("SettingsRow", "AircToggleRow"):
                labelled, end = args(toks, i + 1)
                if t.text == "SettingsRow":
                    titles = literals(arg(labelled, "title"))
                else:
                    titles = literals(labelled[0][1]) if labelled and labelled[0][0] is None else []
                sub = literals(arg(labelled, "subtitle"))
                if titles:
                    self.add(page, "row", titles[0], section, sub[0] if sub else None, titles[1:])
                i = end + 1
                continue
            if called and t.text in self.table and t.text[0].isupper():
                self.walk_struct(page, t.text, section)
            i += 1

    def add(self, page, kind, title, section, detail, alternates):
        key = (page, kind, title, section)
        if any((e[0], e[1], e[2], e[3]) == key for e in self.entries):
            return
        self.entries.append((page, kind, title, section, detail, alternates))


def page_roots(table):
    """[(case, struct)] from SettingsRoot's `page` switch, in SettingsPage's order."""
    with open(os.path.join(SRC, "Settings/SettingsWindow.swift"), encoding="utf-8") as f:
        text = f.read()
    m = re.search(r"@ViewBuilder private var page: some View \{(.*?)\n    \}\n", text, re.S)
    if not m:
        sys.exit("settings-search-index: SettingsRoot's page switch not found")
    roots = []
    for case, rest in re.findall(r"case \.(\w+): (.*)", m.group(1)):
        for name in re.findall(r"\b([A-Z]\w+)\(", rest):
            if name in table:
                roots.append((case, name))
                break
        else:
            sys.exit(f"settings-search-index: no view for .{case}")
    return roots


def swift(s):
    return '"' + s + '"'


def render(entries):
    out = ["// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0",
           "// Generated by scripts/settings-search-index.py from the Settings panes' sources. Don't edit by hand: run",
           "// the script after changing a pane's sections or rows (the settingsux check fails when this is stale).",
           "",
           "extension SettingsSearch {",
           "    /// Every literal section and row of every pane, in the order the panes show them.",
           "    static let catalog: [Entry] = ["]
    for page, kind, title, section, detail, alts in entries:
        parts = [f".{page}", swift(title)]
        if section is not None:
            parts.append("section: " + swift(section))
        if detail is not None:
            parts.append("detail: " + swift(detail))
        if alts:
            parts.append("alternates: [" + ", ".join(swift(a) for a in alts) + "]")
        out.append(f"        .{kind}(" + ", ".join(parts) + "),")
    out += ["    ]", "}", ""]
    return "\n".join(out)


def main():
    files = []
    for d, dirs, names in os.walk(SRC):
        dirs[:] = sorted(x for x in dirs if x not in SKIP_DIRS)
        for name in sorted(names):
            if name.endswith(".swift") and name != os.path.basename(OUT):
                with open(os.path.join(d, name), encoding="utf-8") as f:
                    files.append(lex(f.read()))
    table = structs(files)
    w = Walker(table)
    for case, name in page_roots(table):
        w.walk_struct(case, name, None)
    text = render(w.entries)
    if "--check" in sys.argv:
        old = open(OUT, encoding="utf-8").read() if os.path.exists(OUT) else ""
        if old != text:
            import difflib
            sys.stdout.writelines(difflib.unified_diff(old.splitlines(True), text.splitlines(True), "catalog", "sources"))
            print("settings-search-index: the catalog is stale; run scripts/settings-search-index.py")
            return 1
        print(f"settings-search-index: up to date ({len(w.entries)} entries)")
        return 0
    with open(OUT + ".tmp", "w", encoding="utf-8") as f:
        f.write(text)
    os.replace(OUT + ".tmp", OUT)
    print(f"settings-search-index: wrote {len(w.entries)} entries")
    return 0


if __name__ == "__main__":
    sys.exit(main())
