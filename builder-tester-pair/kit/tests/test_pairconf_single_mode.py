#!/usr/bin/env python3
"""Regression tests for the single-workspace namespace check (review of PR #230: findings 1-3).

Run:  python3 kit/tests/test_pairconf_single_mode.py
The unshare test REFUSES (exit 2, "SKIP") when unprivileged user namespaces are unavailable, so it can never report
"no gap" on a box where it could not look. Each test was run against the previous code first and failed there."""
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest

LIB = pathlib.Path(__file__).resolve().parents[1] / "lib"
sys.path.insert(0, str(LIB))
import pairconf  # noqa: E402

# Fixtures are written as JSON, which is also valid YAML: pairconf falls back to json when PyYAML is missing, so both parsers read them.
CFG_SINGLE = {"guard": {"workspace_mode": "single"}, "builder": {"name": "B", "host": "*", "user": "%(me)s"},
              "tester": {"name": "T", "host": "*", "user": "someone-else"}}


def _cfg(obj):
    d = tempfile.mkdtemp()
    p = pathlib.Path(d) / "pair.yaml"
    p.write_text(json.dumps(obj).replace("%(me)s", pairconf._current_user()))
    return str(p)


def _userns_available():
    r = subprocess.run(["unshare", "-U", "-r", "true"], capture_output=True)
    return r.returncode == 0


class SingleMode(unittest.TestCase):
    def test_identity_uid_map_parser(self):
        d = tempfile.mkdtemp()
        for text, want in (("         0          0 4294967295\n", True), ("         0       1000          1\n", False),
                           ("0 0 1\n", False), ("", False), ("0 0 4294967295\n0 5 1\n", False), ("x y z\n", False)):
            p = pathlib.Path(d) / "m"
            p.write_text(text)
            self.assertEqual(pairconf._identity_uid_map(str(p)), want, repr(text))
        self.assertFalse(pairconf._identity_uid_map(str(pathlib.Path(d) / "missing")))   # unreadable -> fail closed

    @unittest.skipUnless(_userns_available(), "unprivileged user namespaces unavailable: refusing to report 'no gap'")
    def test_new_user_namespace_is_not_trusted_in_single_mode(self):
        # A SHELL runs inside the namespace (exec'ing python directly leaves no readable candidate and proves nothing).
        cfg = _cfg(CFG_SINGLE)
        probe = ("import sys; sys.path.insert(0, %r); import pairconf; "
                 "print(pairconf.initial_namespaces(pairconf.load(%r)))") % (str(LIB), cfg)
        env = dict(os.environ, PAIR_CONFIG=cfg)
        # The trailing `:` stops bash exec'ing python directly: a shell must stay alive INSIDE the namespace, otherwise
        # there is no readable candidate, the guard returns False for the wrong reason and the test could never fail.
        out = subprocess.run(["unshare", "-U", "-r", "-u", "bash", "-c", 'python3 -c "$0"; :', probe],
                             capture_output=True, text=True, env=env).stdout.strip()
        self.assertEqual(out, "False", "a process inside `unshare -U -r -u` must not be trusted")
        outside = subprocess.run(["python3", "-c", probe], capture_output=True, text=True, env=env).stdout.strip()
        self.assertEqual(outside, "True", "control: the same probe outside the namespace is trusted")

    def test_single_mode_requires_role_user(self):
        cfg = pairconf.load(_cfg({"guard": {"workspace_mode": "single"}, "builder": {"name": "B", "host": "*"},
                                  "tester": {"name": "T", "host": "*"}}))
        self.assertEqual(pairconf.role(cfg, host="anything"), "unknown")      # was: everything resolved to builder
        sep = pairconf.load(_cfg({"builder": {"name": "B", "host": "*"}, "tester": {"name": "T", "host": "*"}}))
        self.assertEqual(pairconf.role(sep, host="anything"), "builder")      # separate mode unchanged


if __name__ == "__main__":
    unittest.main()
