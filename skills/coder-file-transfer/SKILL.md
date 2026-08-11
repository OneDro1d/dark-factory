---
name: coder-file-transfer
description: Upload or download large files to/from a Coder CDE workspace using the coder CLI. Use when transferring files, directories, build artifacts, datasets, or binaries to a Coder workspace, when `rsync -e "coder ssh"` fails or desyncs, or when a copy over `coder ssh` hangs/corrupts. Triggers on "upload to coder", "copy files to workspace", "coder scp", "coder rsync", "transfer to CDE", "push files to my workspace", "coder config-ssh".
allowed-tools: Read, Bash(coder:*), Bash(rsync:*), Bash(scp:*), Bash(ssh:*), Bash(brew:*), Bash(mkdir:*)
---

# Coder Workspace File Transfer

Move large files to (or from) a Coder Cloud Development Environment reliably. The naive
path — `rsync -e "coder ssh"` — is broken on macOS. Use a `coder config-ssh` host alias
with a protocol-clean, PTY-free SSH channel instead.

## When to use

- Uploading a directory, dataset, build artifact, or binary to a Coder workspace.
- `rsync -e "coder ssh"` fails, desyncs mid-transfer, or hangs.
- A copy over `coder ssh` corrupts or never completes.
- You need a **resumable** transfer over a flaky dev tunnel.

## The one-liner

```bash
coder config-ssh                                          # one-time per machine
rsync -avP -e "ssh -T" /local/dir <workspace>.coder:/remote/target/dir/
```

## Instructions

1. **Generate SSH host aliases (one-time per machine/workspace):**
   ```bash
   coder config-ssh
   ```
   This adds host entries to `~/.ssh/config`. Note the alias for your workspace from the
   output — typically `<workspace>.coder` (e.g. workspace `Loom` → host `Loom.coder`).

2. **Confirm you have GNU rsync (macOS ships the incompatible `openrsync`):**
   ```bash
   rsync --version
   ```
   If it says `openrsync`, install GNU rsync:
   ```bash
   brew install rsync
   ```

3. **Ensure the remote target directory exists:**
   ```bash
   coder ssh <workspace> -- mkdir -p /remote/target/dir
   ```

4. **Transfer — preferred (resumable):**
   ```bash
   rsync -avP -e "ssh -T" /local/dir <workspace>.coder:/remote/target/dir/
   ```
   - `-a` archive, `-v` verbose, `-P` = `--partial --progress` → **resumable**.
   - `-e "ssh -T"` disables PTY allocation — **the essential fix**.

5. **Transfer — fallback (no resume):**
   ```bash
   scp -r /local/dir <workspace>.coder:/remote/target/dir/
   ```

6. **Download (reverse direction)** — swap the arguments:
   ```bash
   rsync -avP -e "ssh -T" <workspace>.coder:/remote/dir ./local/target/
   ```

## What NOT to do

- ❌ `rsync -e "coder ssh" src host:dst` — macOS `openrsync` desyncs against the remote
  GNU rsync; even with GNU rsync, `coder ssh`'s PTY corrupts the byte stream.
- ❌ Omitting `-e "ssh -T"` — the default TTY allocation breaks rsync/tar pipelines.
- ❌ Trusting the macOS built-in `rsync` — always verify `rsync --version` reports GNU.

## Why this works

`coder config-ssh` turns the Coder tunnel into a standard SSH host. Any TCP-clean SSH
tool (rsync, scp, sftp) then works directly, instead of being wrapped by `coder ssh`,
which forces a PTY. Removing the PTY (`ssh -T`) and using GNU rsync's protocol gives a
clean binary channel that survives large, resumable transfers.

## Reference

Full write-up with the failure matrix and a concrete Loom example:
`docs/coder-large-file-upload.md`.
