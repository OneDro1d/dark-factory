Executables placed here join the Bash tool's `PATH` while this plugin is enabled — inside a
Claude session only. In a plain shell nothing here resolves; the Tier-3 installer's own links
(`~/.local/bin/df-mission`, `df-preflight`, …) are what a terminal sees.

What lives here, and why each one:

- `df-worker` — the headless worker launcher. Reached by the estate's `dispatch.sh` shim on PATH
  first, then by path under the vendored Tier 1, then under the installed plugin.
- `mission-tick.sh` — the monitor `monitors/monitors.json` points at (invariant I4 checks that
  every monitor command names a file here that exists).

⚠️ An earlier version of this file promised *"only two shims — `df-mission` and `df-worker`"*.
There is no `df-mission` here and never was: `df-mission` is an engine script the Tier-3
installer links on PATH directly, and a second copy of it under a plugin would be the two-homes
failure this repo keeps finding. The list above is the truth; the invariant tests, not this
prose, are what hold it.

This directory must never become a copy of the engine directory itself: on the machine this
plugin's design was measured against, the engine's own `boot-kit/scripts/` holds eleven other
files, including `verify-kit.sh` and `sync-check.sh`, plus the maintainer's real, gitignored
`landmarks.conf` — none of which belongs in a public, pinned plugin tree. `bin/` therefore ships
a named file list, never a directory copy.
