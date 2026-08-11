#!/usr/bin/env python3
"""Dependency-free pytest-lite runner (fallback for run-tests.sh).

The plugin's hard constraint is bash + python3 + jq ONLY, but the U6 adapter tests
are written as pytest test_* functions using the `tmp_path` fixture. When pytest is
installed, run-tests.sh uses it. When it is NOT, run-tests.sh falls back to this
runner, which imports each given test module, supplies a fresh `tmp_path`
(tempfile-backed pathlib.Path) to any test that requests it, invokes every top-level
`test_*` function, and reports pass/fail counts.

Usage:  _pyrun.py <test_file.py> [<test_file.py> ...]
Exit:   0 if all tests passed, 1 otherwise.

Supported fixtures: `tmp_path` (a unique Path per test). That is all the plugin's
python tests use; unknown fixtures raise a clear error (counted as a failure) rather
than silently passing.
"""
import importlib.util
import inspect
import sys
import tempfile
import traceback
from pathlib import Path

GREEN, RED, BOLD, RESET = "\033[32m", "\033[31m", "\033[1m", "\033[0m"


def _load_module(path: Path):
    spec = importlib.util.spec_from_file_location(path.stem, str(path))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _make_arg(name: str):
    if name == "tmp_path":
        return Path(tempfile.mkdtemp(prefix="pyrun-"))
    raise KeyError(f"unsupported fixture: {name!r}")


def run_file(path: Path):
    passed = failed = 0
    try:
        mod = _load_module(path)
    except Exception:
        print(f"{RED}FAIL{RESET} import {path.name}")
        traceback.print_exc()
        return 0, 1

    tests = [
        (n, f) for n, f in inspect.getmembers(mod, inspect.isfunction)
        if n.startswith("test_") and f.__module__ == mod.__name__
    ]
    print(f"{BOLD}{path.name}{RESET} ({len(tests)} tests)")
    for name, fn in sorted(tests, key=lambda t: t[0]):
        try:
            params = inspect.signature(fn).parameters
            kwargs = {p: _make_arg(p) for p in params}
            fn(**kwargs)
            passed += 1
        except Exception as exc:  # AssertionError or any raise = failure
            failed += 1
            print(f"  {RED}FAIL{RESET} {name}: {exc.__class__.__name__}: {exc}")
    return passed, failed


def main(argv):
    files = [Path(a) for a in argv[1:]]
    if not files:
        print("usage: _pyrun.py <test_file.py> ...", file=sys.stderr)
        return 2
    total_p = total_f = 0
    for f in files:
        p, fl = run_file(f)
        total_p += p
        total_f += fl
    color = GREEN if total_f == 0 else RED
    print(f"\n{total_p + total_f} py-tests: "
          f"{GREEN}{total_p} passed{RESET}, {color}{total_f} failed{RESET}")
    return 0 if total_f == 0 else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
