#!/usr/bin/env bash
set -euo pipefail

is_interactive() {
  [[ -t 0 && -t 1 ]]
}

ensure_cmd() {
  local c="$1"
  local pkg="$2"
  if command -v "$c" >/dev/null 2>&1; then
    return 0
  fi
  echo "Missing dependency: $c" >&2
  if command -v apt-get >/dev/null 2>&1; then
    echo "Install with: apt-get update && apt-get install -y $pkg" >&2
  fi
  return 1
}

ensure_docker_compose() {
  if docker compose version >/dev/null 2>&1; then
    return 0
  fi

  echo "docker compose (Compose v2 plugin) not available" >&2

  if ! command -v apt-get >/dev/null 2>&1; then
    return 1
  fi

  if ! is_interactive; then
    echo "Install with: apt-get update && apt-get install -y docker-compose-plugin" >&2
    return 1
  fi

  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "Install requires root: apt-get update && apt-get install -y docker-compose-plugin" >&2
    return 1
  fi

  read -r -p "Install docker-compose-plugin via apt-get? [y/N]: " ans
  if [[ "${ans,,}" != "y" ]]; then
    return 1
  fi

  apt-get update
  apt-get install -y docker-compose-plugin
  docker compose version >/dev/null 2>&1
}

ensure_host_deps() {
  local missing=0

  ensure_cmd mountpoint util-linux || missing=1
  ensure_docker_compose || missing=1

  if [[ $missing -ne 0 ]]; then
    exit 1
  fi

  if command -v fusermount >/dev/null 2>&1 || command -v fusermount3 >/dev/null 2>&1; then
    return 0
  fi

  if ! command -v apt-get >/dev/null 2>&1; then
    return 0
  fi

  if ! is_interactive; then
    echo "Optional dependency missing: fusermount/fusermount3 (for cleaner FUSE unmount)." >&2
    echo "Install with: apt-get update && apt-get install -y fuse3" >&2
    return 0
  fi

  read -r -p "Install fuse3 (provides fusermount3) via apt-get? [y/N]: " ans
  if [[ "${ans,,}" != "y" ]]; then
    return 0
  fi
  apt-get update
  apt-get install -y fuse3
}

write_env_file() {
  mkdir -p /etc/htpc
  cat >/etc/htpc/htpc.env <<EOF
HTPC_HOME=$HTPC_HOME
REMOTE_MNT=$REMOTE_MNT
REPO_ROOT=$REPO_ROOT
COMPOSE_ENV_FILE=$COMPOSE_ENV_FILE
COMPOSE_FILE=$COMPOSE_FILE
EOF
  chmod 0600 /etc/htpc/htpc.env
}

bootstrap_env_if_needed() {
  if [[ -f /etc/htpc/htpc.env ]]; then
    # shellcheck disable=SC1091
    . /etc/htpc/htpc.env
  fi

  if [[ -n "${HTPC_HOME:-}" && -n "${REMOTE_MNT:-}" && -n "${COMPOSE_FILE:-}" && -n "${COMPOSE_ENV_FILE:-}" && -n "${REPO_ROOT:-}" ]]; then
    return 0
  fi

  if ! is_interactive; then
    echo "Missing required config (expected in /etc/htpc/htpc.env). Run interactively once to generate it." >&2
    exit 1
  fi

  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "Missing required config (expected in /etc/htpc/htpc.env). Run as root interactively once to generate it." >&2
    exit 1
  fi

  read -r -p "HTPC_HOME (e.g. /home/orangepi): " HTPC_HOME
  read -r -p "REMOTE_MNT (e.g. /mnt/remote): " REMOTE_MNT

  REPO_ROOT_DEFAULT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  if [[ -d "$REPO_ROOT_DEFAULT/Compose" ]]; then
    read -r -p "REPO_ROOT [$REPO_ROOT_DEFAULT]: " REPO_ROOT
    REPO_ROOT="${REPO_ROOT:-$REPO_ROOT_DEFAULT}"
  else
    read -r -p "REPO_ROOT (path to htpc repo): " REPO_ROOT
  fi

  COMPOSE_ENV_FILE="$REPO_ROOT/Compose/.htpc.env"
  COMPOSE_FILE="$REPO_ROOT/Compose/htpc jellyfin.yaml"

  mkdir -p "$(dirname "$COMPOSE_ENV_FILE")"
  cat >"$COMPOSE_ENV_FILE" <<EOF
HTPC_HOME=$HTPC_HOME
REMOTE_MNT=$REMOTE_MNT
EOF

  write_env_file
}

ensure_host_deps

bootstrap_env_if_needed

if [[ -f /etc/htpc/htpc.env ]]; then
  # shellcheck disable=SC1091
  . /etc/htpc/htpc.env
fi

if [[ -z "${HTPC_HOME:-}" || -z "${REMOTE_MNT:-}" ]]; then
  echo "HTPC_HOME and REMOTE_MNT must be set (expected in /etc/htpc/htpc.env)" >&2
  exit 1
fi

if [[ -z "${COMPOSE_FILE:-}" || -z "${COMPOSE_ENV_FILE:-}" || -z "${REPO_ROOT:-}" ]]; then
  echo "COMPOSE_FILE, COMPOSE_ENV_FILE, and REPO_ROOT must be set (expected in /etc/htpc/htpc.env)" >&2
  exit 1
fi

if ! docker compose version >/dev/null 2>&1; then
  echo "docker compose not available" >&2
  exit 1
fi

REALDEBRID_MNT="$REMOTE_MNT/realdebrid"
TORBOX_MNT="$REMOTE_MNT/torbox"

FUSERMOUNT_BIN=""
if command -v fusermount >/dev/null 2>&1; then
  FUSERMOUNT_BIN="fusermount"
elif command -v fusermount3 >/dev/null 2>&1; then
  FUSERMOUNT_BIN="fusermount3"
fi

echo "Stopping rclone services via compose..."
docker compose --env-file "$COMPOSE_ENV_FILE" -f "$COMPOSE_FILE" stop rclone-zurg rclone-torbox || true

echo "Waiting for containers to stop..."
sleep 3

echo "Force unmounting rclone mount points..."
for mnt in "$REALDEBRID_MNT" "$TORBOX_MNT"; do
  if mountpoint -q "$mnt"; then
    echo "Unmounting $mnt"
    if [[ -n "$FUSERMOUNT_BIN" ]]; then
      "$FUSERMOUNT_BIN" -uz "$mnt" || umount -lf "$mnt"
    else
      umount -lf "$mnt"
    fi
  else
    echo "$mnt not mounted"
  fi
done

echo "Clearing rclone cache..."
rm -rf "$HTPC_HOME/.cache/rclone"/* || true
rm -rf "$HTPC_HOME/.cache/rclone/torbox"/* || true

echo "Restarting rclone services via compose..."
docker compose --env-file "$COMPOSE_ENV_FILE" -f "$COMPOSE_FILE" up -d rclone-zurg rclone-torbox

echo "Done."
