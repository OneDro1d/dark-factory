Executables placed here join the Bash tool's `PATH` while this plugin is enabled. Only two shims
will ever live in this directory — `df-mission` and `df-worker` — and each `exec`s the real engine
copied elsewhere by the Tier-3 installer. This directory must never become a copy of the engine
directory itself: on the machine this plugin's design was measured against, the engine's own
`boot-kit/scripts/` holds eleven other files, including `verify-kit.sh` and `sync-check.sh`, plus
the maintainer's real, gitignored `landmarks.conf` — none of which belongs in a public, pinned
plugin tree. `bin/` therefore ships a named file list of shims, never a directory copy.
