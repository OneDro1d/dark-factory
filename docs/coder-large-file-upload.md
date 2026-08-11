# Uploading Large Files to a Coder Workspace (coder CLI)

**TL;DR** — `rsync -e "coder ssh"` is broken on macOS. Instead run `coder config-ssh`
once, then push files over the generated SSH host alias with **GNU** `rsync -avP -e "ssh -T"`
(resumable) or `scp -r` (fallback). Verified working 2026-06-26.

```bash
# One-time per machine/workspace
coder config-ssh                      # writes host aliases into ~/.ssh/config

# Preferred: resumable, shows progress
rsync -avP -e "ssh -T" /local/dir <workspace>.coder:/remote/target/dir/

# Fallback: no resume
scp -r /local/dir <workspace>.coder:/remote/target/dir/
```

---

## What does NOT work

| Approach | Failure |
|---|---|
| `rsync -e "coder ssh" src host:dst` | macOS ships **`openrsync`**, which desyncs against the remote **GNU rsync** protocol. |
| — same, with GNU rsync installed | `coder ssh` allocates a **PTY**; rsync/tar ride a clean binary pipe, and the PTY corrupts it. |

Both failures are transport-layer, not Coder-side. The fix removes the PTY and uses a
protocol-clean SSH channel.

## What works

### 1. Generate SSH host aliases (one-time)

```bash
coder config-ssh
```

This writes entries into `~/.ssh/config` for each of your workspaces. The host alias is
shown in the command output and in `~/.ssh/config` — typically `<workspace>.coder` (e.g.
a workspace named `Loom` → host `Loom.coder`). Use that alias with any standard SSH tool.

### 2a. Preferred — GNU rsync (resumable)

```bash
rsync -avP -e "ssh -T" /local/dir <workspace>.coder:/remote/target/dir/
```

- `-a` archive · `-v` verbose · `-P` = `--partial --progress` → **resumable** on drop.
- `-e "ssh -T"` — disables PTY allocation. **This is the key fix.**
- Requires **GNU rsync** locally (macOS default `openrsync` will not work):
  ```bash
  brew install rsync
  rsync --version   # must say "rsync ... protocol version 3x" (GNU), not openrsync
  ```

### 2b. Fallback — scp (no resume)

```bash
scp -r /local/dir <workspace>.coder:/remote/target/dir/
```

Works over the same alias but restarts from zero on any interruption. Prefer rsync for
large uploads over a dev tunnel, which drops.

## Why `config-ssh` is the enabler

`coder config-ssh` turns the Coder tunnel into a standard SSH host. Once it's a plain SSH
host, any TCP-clean SSH tool (rsync, scp, sftp) works directly — instead of being wrapped
by `coder ssh`, which forces a PTY. The PTY is what breaks rsync/tar pipelines.

## Gotchas

- **`openrsync` vs GNU rsync** — the macOS built-in silently negotiates a different protocol
  and desyncs mid-transfer. Verify `rsync --version` reports GNU before trusting a large push.
- **PTY** — never omit `-e "ssh -T"`; the default TTY allocation corrupts the byte stream.
- **Target dir must exist** — create it on the workspace first (`coder ssh <workspace> -- mkdir -p /remote/target/dir`) or the copy fails.
- **Resume** — only `rsync -P` resumes; `scp -r` does not.

## Concrete example (Loom workspace)

```bash
coder config-ssh
rsync -avP -e "ssh -T" ./bigdir Loom.coder:/fleet/fleet/loom/uploads/
```

`/fleet/fleet/loom/uploads/` is the standard upload target on the Loom workspace.

---

_Source: verified during Loom fleet operations, 2026-06-26. See skill `coder-file-transfer`._
