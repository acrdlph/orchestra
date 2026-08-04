#!/usr/bin/env python3
"""The two promises no passing test can make on its own — checked mechanically.

docs/mobile/ARCHITECTURE.md §4.5 specifies both of these, and both are AST
walks rather than behaviour tests for the same reason: what they forbid does
not fail, it *works* — right up until the day somebody else runs the code.

**TestZeroDeps.** "Zero dependencies — python3 stdlib only" is the first
sentence of the package docstring and the reason a stranger can clone this and
run it. A green suite proves nothing about it: whatever the author `pip
install`ed years ago is on the author's machine and imports fine. So every
`import` in `orchestra/` and `tests/` is read out of the AST and checked
against a NAMED allowlist, and the allowlist is itself checked against
`sys.stdlib_module_names` — a list that could quietly grow a third-party name
would be a rubber stamp.

Imports alone are not the promise, which is why §4.5 says so explicitly: "the
previous formulation checked imports only, which would have passed while the
promise was broken by a subprocess." A `run(["ripgrep", …])` needs no import
and breaks the promise just as completely, so every literal `argv[0]` this
codebase shells out to is checked against a second named allowlist. And a
dynamic `__import__(name)` on a computed string is a hole in the first check
big enough to drive anything through, so it is refused outright — the same
argument `tests/test_pairing.py` makes about `__import__('random')`.

**TestMockability.** The suite mocks by assigning module attributes, which
works only because callers resolve through the module namespace at CALL time:

    from . import shell            # yes
    rc, out = shell.run(["git", "status"])

    from .shell import run         # NO — freezes the real subprocess into
                                  # this module and every `shell.run` patch
                                  # in the suite silently misses it

`orchestra/shell.py` says this in its own docstring; this test is what makes it
true. The failure mode is the dangerous kind: the patch still applies, the test
still passes, and the code under test quietly ran the real thing.

Neither test imports orchestra. They read the source, so they hold even for a
module that cannot be imported at all.
"""

import ast
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PACKAGE = ROOT / "orchestra"
SUITE = ROOT / "tests"

# ---------------------------------------------------------------- allowlists

# Every stdlib module this project imports, written down. Adding a line here is
# a deliberate act; `sys.stdlib_module_names` is checked against it below so a
# non-stdlib name cannot be smuggled in by editing this set alone.
STDLIB_USED = frozenset({
    "argparse", "ast", "base64", "collections", "concurrent", "contextlib",
    "dataclasses", "datetime", "errno", "fcntl", "getpass", "hashlib", "hmac",
    "http", "importlib", "io", "ipaddress", "itertools", "json", "math", "os",
    "pathlib", "queue", "re", "secrets", "select", "shlex", "shutil", "socket",
    "socketserver", "stat", "struct", "subprocess", "sys", "tempfile",
    "threading", "time", "types", "unittest", "urllib", "zlib",
})

# First-party roots: the package, and the suite's own helper modules, which the
# tests reach both as `tests.<name>` and bare (they insert `tests/` on the path).
FIRST_PARTY = frozenset({
    "orchestra", "tests", "characterize", "git_equiv", "qr_ref",
    "test_auth", "test_integration", "test_observer",
})

# Every binary orchestra may start. `shell.run` is the one door (its docstring
# names this list in prose); `tailnet._run` is the second, deliberately outside
# `shell` because it must not be patchable by the suite's `shell.run` seam.
#
# All of them are optional except `git`: `run` answers a missing binary with
# `(1, "")` and the caller degrades. That is the whole reason this list can
# stay short — a feature that needs a new binary is a feature that must decide,
# out loud, what it does on a machine without it.
BINARIES = frozenset({
    "git",                       # worktrees, branches, topology, closeout
    "ps", "lsof",                # live claude processes and their cwds
    "osascript", "open",         # macOS terminal actuation (focus, typing)
    "tmux",                      # dispatch, resume, chat into fleet panes
    "curl",                      # APNs over HTTP/2 — stdlib speaks no h2
    "openssl",                   # ES256 for the APNs provider token
    "ifconfig", "/sbin/ifconfig",   # tailnet address detection, no CLI needed
})

# What the suite additionally shells out to. Every one of these self-skips when
# absent (`shutil.which`), so none of them is a dependency of the app.
TEST_BINARIES = BINARIES | {
    "sh",                        # a plain shell as a stand-in for a hook
}

# The one file allowed to from-import lowercase names, and why. `__init__.py`
# IS the facade — its entire body is the re-export surface that lets tests,
# tools and tests/characterize.py keep saying `orchestra.<name>` across the
# package split (ARCHITECTURE §4.5 names the 307 `fb.` references it carries).
# It is not a consumer resolving a name at call time; it is the namespace those
# consumers resolve THROUGH, so the hazard the rule guards against cannot arise
# there. Its own docstring records the names deliberately left OUT — anything
# rebound at runtime, which a facade copy would freeze.
FACADE = frozenset({"orchestra/__init__.py"})

SHELL_CALLS = frozenset({"run", "_run", "Popen", "check_output", "call",
                         "check_call"})
DYNAMIC_IMPORTS = frozenset({"__import__", "import_module"})


def _sources(*dirs):
    """(relative path, parsed AST) for every .py under each dir."""
    for d in dirs:
        for f in sorted(d.rglob("*.py")):
            yield f.relative_to(ROOT).as_posix(), ast.parse(f.read_text(), str(f))


def _call_name(node):
    """The bare name a Call is calling: `shell.run(...)` and `run(...)` both
    read as `run`, which is the point — the seam is the name, not the path to
    it."""
    fn = node.func
    if isinstance(fn, ast.Attribute):
        return fn.attr
    if isinstance(fn, ast.Name):
        return fn.id
    return None


# --------------------------------------------------------------- zero deps

class TestZeroDeps(unittest.TestCase):

    def test_the_allowlist_is_entirely_stdlib(self):
        """The gate on the gate. STDLIB_USED is hand-written, so on its own it
        proves only that somebody typed a name into it."""
        outside = sorted(STDLIB_USED - set(sys.stdlib_module_names))
        self.assertEqual([], outside,
                         f"STDLIB_USED names something Python does not ship: {outside}")

    def test_every_import_is_stdlib_or_first_party(self):
        bad = []
        for path, tree in _sources(PACKAGE, SUITE):
            for node in ast.walk(tree):
                if isinstance(node, ast.Import):
                    roots = [a.name.split(".")[0] for a in node.names]
                elif isinstance(node, ast.ImportFrom):
                    # a relative import is inside this package by construction
                    roots = [] if node.level or not node.module \
                        else [node.module.split(".")[0]]
                else:
                    continue
                for root in roots:
                    if root not in STDLIB_USED and root not in FIRST_PARTY:
                        bad.append(f"{path}:{node.lineno} imports {root!r}")
        self.assertEqual([], bad, "zero dependencies is the promise:\n" +
                         "\n".join(bad))

    def test_no_dynamic_import_takes_a_computed_name(self):
        """`__import__(whatever_this_is)` would walk straight past the check
        above. A constant is still checked (it is an import); a non-constant
        cannot be, so it is refused."""
        bad = []
        for path, tree in _sources(PACKAGE, SUITE):
            for node in ast.walk(tree):
                if not isinstance(node, ast.Call):
                    continue
                if _call_name(node) not in DYNAMIC_IMPORTS or not node.args:
                    continue
                arg = node.args[0]
                if not isinstance(arg, ast.Constant) or not isinstance(arg.value, str):
                    bad.append(f"{path}:{node.lineno} imports a computed name")
                elif arg.value.split(".")[0] not in STDLIB_USED | FIRST_PARTY:
                    bad.append(f"{path}:{node.lineno} imports {arg.value!r}")
        self.assertEqual([], bad, "\n".join(bad))

    def test_every_shelled_binary_is_on_the_allowlist(self):
        """§4.5: checking imports alone would pass while a subprocess broke the
        promise. A non-literal `argv[0]` is not checked here — it cannot be —
        which is why the allowlist above is prose as well as a set."""
        bad = []
        for root, allowed in ((PACKAGE, BINARIES), (SUITE, TEST_BINARIES)):
            for path, tree in _sources(root):
                for node in ast.walk(tree):
                    if not isinstance(node, ast.Call):
                        continue
                    if _call_name(node) not in SHELL_CALLS or not node.args:
                        continue
                    argv = node.args[0]
                    if not isinstance(argv, (ast.List, ast.Tuple)) or not argv.elts:
                        continue
                    head = argv.elts[0]
                    if not isinstance(head, ast.Constant) or \
                            not isinstance(head.value, str):
                        continue
                    if head.value not in allowed:
                        bad.append(f"{path}:{node.lineno} runs {head.value!r}")
        self.assertEqual([], bad, "an undeclared binary is a dependency:\n" +
                         "\n".join(bad))


# ------------------------------------------------------------- mockability

class TestMockability(unittest.TestCase):

    @staticmethod
    def _internal(node):
        """Does this `from X import …` name a MODULE INSIDE the package?

        `from . import config` and `from orchestra import notify` do not — the
        names they bind ARE modules, which is the form the rule asks for.
        `from .config import …` and `from orchestra.notify import …` do: the
        names they bind are attributes, resolved once, at import time.
        """
        if node.level and node.module:
            return True
        return bool(node.module) and node.module.split(".")[0] == "orchestra" \
            and "." in node.module

    def test_no_module_level_from_import_of_a_function(self):
        bad = []
        for path, tree in _sources(PACKAGE, SUITE):
            if path in FACADE:
                continue
            for node in ast.walk(tree):
                if not isinstance(node, ast.ImportFrom) or not self._internal(node):
                    continue
                for alias in node.names:
                    # Leading underscores stripped first: `_base_ref` is as
                    # frozen as `base_ref`. A CapWords name is a class and a
                    # SHOUTING one a constant — both are values a caller is
                    # meant to hold, and neither is a seam.
                    bare = alias.name.lstrip("_")
                    if bare and bare[0].islower():
                        bad.append(f"{path}:{node.lineno} "
                                   f"from {'.' * node.level}{node.module or ''} "
                                   f"import {alias.name}")
        self.assertEqual([], bad, "import the module, not the name — "
                         "ARCHITECTURE §4.5:\n" + "\n".join(bad))

    def test_the_facade_allowlist_names_files_that_exist(self):
        """An allowlist entry for a file that moved is an exemption nobody can
        see any more."""
        for rel in FACADE:
            self.assertTrue((ROOT / rel).is_file(), f"{rel} is not there")


if __name__ == "__main__":
    unittest.main()
