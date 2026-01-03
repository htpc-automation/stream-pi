# stream-pi

`stream-pi` is a small, copy/paste-friendly set of shell scripts for bringing up (and maintaining) a Docker-based “headless HTPC” stack on Debian-family Linux.

The goal is to keep setup simple:

- **One installer script** that asks you for a few values (or accepts flags) and writes the minimal config it needs.
- **One maintenance script** that can reset flaky rclone mount containers safely (stop, unmount, clear cache, restart).
- **Optional systemd unit** so you can run the reset automatically.

## What it does

This repo contains:

- `docker/` docker compose files for the stack.
- `services/install-debian.sh` installer that:
  - Prompts for required values.
  - Writes `/etc/htpc/htpc.env`.
  - Installs helper scripts to `/usr/local/bin/`.
  - Installs/enables a systemd service.
- `services/htpc-reset-rclone-mounts.sh` maintenance script that:
  - Stops the rclone containers via `docker compose`.
  - Unmounts the mount points.
  - Clears rclone cache.
  - Brings the rclone services back up.

## Requirements

- Debian-family Linux (Debian/Ubuntu/Armbian/etc.)
- Run as `root` (or via `sudo`)
- Docker installed and working
- `docker compose` (Compose v2 plugin)

The reset script will offer to install missing dependencies via `apt-get` when run interactively.

## One-copy/paste quickstart (fresh box)

Run this on your Linux box as root. It will download the repo ZIP, extract it, and run the installer:

```bash
bash -lc 'set -euo pipefail
tmp="$(mktemp -d)"
trap "rm -rf \"$tmp\"" EXIT
curl -fsSL "https://github.com/htpc-automation/stream-pi/archive/refs/heads/main.zip" -o "$tmp/stream-pi.zip"
unzip -q "$tmp/stream-pi.zip" -d "$tmp"
repo_dir="$tmp/stream-pi-main"
chmod +x "$repo_dir/services/install-debian.sh"
exec "$repo_dir/services/install-debian.sh"'
```

If your default branch is not `main`, change the URL accordingly.

## Installer script usage

The installer is:

- `services/install-debian.sh`

It supports flags (and will prompt for anything missing):

```bash
/path/to/repo/services/install-debian.sh \
  --htpc-home /home/orangepi \
  --remote-mnt /mnt/remote \
  --rd-api-key "..." \
  --torbox-user "you@example.com" \
  --torbox-pass "..."
```

### What it writes

- `/etc/htpc/htpc.env`
  - This is the canonical config file used by the scripts and the systemd unit.
- `docker/.htpc.env`
  - Compose `--env-file` values (paths, mount root, etc.).

## “Reset rclone mounts” script

The reset script is:

- `services/htpc-reset-rclone-mounts.sh`

Behavior:

- If `/etc/htpc/htpc.env` is missing and you run the script interactively as root, it will prompt you and generate the file.
- If run non-interactively (systemd/cron) and config is missing, it fails fast with a clear message.

## systemd

The systemd unit lives at:

- `services/systemd/htpc-reset-rclone-mounts.service`

The installer copies it to `/etc/systemd/system/` and enables it.