#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 [--htpc-home PATH] [--remote-mnt PATH] [--rd-api-key KEY] [--torbox-user USER] [--torbox-pass PASS]" >&2
  exit 2
}

HTPC_HOME=""
REMOTE_MNT=""
RD_API_KEY=""
TORBOX_USER=""
TORBOX_PASS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --htpc-home)
      HTPC_HOME="${2:-}"; shift 2 ;;
    --remote-mnt)
      REMOTE_MNT="${2:-}"; shift 2 ;;
    --rd-api-key)
      RD_API_KEY="${2:-}"; shift 2 ;;
    --torbox-user)
      TORBOX_USER="${2:-}"; shift 2 ;;
    --torbox-pass)
      TORBOX_PASS="${2:-}"; shift 2 ;;
    -h|--help)
      usage ;;
    *)
      echo "Unknown arg: $1" >&2
      usage
      ;;
  esac
done

prompt_if_empty() {
  local var_name="$1"
  local prompt="$2"
  if [[ -z "${!var_name}" ]]; then
    read -r -p "$prompt" "$var_name"
  fi
}

prompt_secret_if_empty() {
  local var_name="$1"
  local prompt="$2"
  if [[ -z "${!var_name}" ]]; then
    read -r -s -p "$prompt" "$var_name"
    echo
  fi
}

prompt_if_empty HTPC_HOME "HTPC_HOME (e.g. /home/orangepi): "
prompt_if_empty REMOTE_MNT "REMOTE_MNT (e.g. /mnt/remote): "
prompt_secret_if_empty RD_API_KEY "RealDebrid API key: "
prompt_if_empty TORBOX_USER "Torbox WebDAV user (email): "
prompt_secret_if_empty TORBOX_PASS "Torbox WebDAV password: "

if [[ -z "$HTPC_HOME" || -z "$REMOTE_MNT" || -z "$RD_API_KEY" || -z "$TORBOX_USER" || -z "$TORBOX_PASS" ]]; then
  echo "Missing required inputs" >&2
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "Please run as root (needed for /etc/htpc and systemd service installation)." >&2
  exit 1
fi

require_cmd() {
  local c="$1"
  if ! command -v "$c" >/dev/null 2>&1; then
    echo "Missing dependency: $c" >&2
    exit 1
  fi
}

require_cmd docker

if ! docker compose version >/dev/null 2>&1; then
  echo "docker compose not available. Install Docker Compose plugin." >&2
  exit 1
fi

mkdir -p "$HTPC_HOME" "$REMOTE_MNT" \
  "$HTPC_HOME/rclone" \
  "$HTPC_HOME/.cache/rclone/torbox" \
  "$HTPC_HOME/zurg" \
  "$HTPC_HOME/zurg/data" \
  "$REMOTE_MNT/realdebrid" \
  "$REMOTE_MNT/torbox"

cat >"$REPO_ROOT/docker/.htpc.env" <<EOF
HTPC_HOME=$HTPC_HOME
REMOTE_MNT=$REMOTE_MNT
EOF

mkdir -p /etc/htpc
cat >/etc/htpc/htpc.env <<EOF
HTPC_HOME=$HTPC_HOME
REMOTE_MNT=$REMOTE_MNT
REPO_ROOT=$REPO_ROOT
COMPOSE_ENV_FILE=$REPO_ROOT/docker/.htpc.env
COMPOSE_FILE=$REPO_ROOT/docker/htpc jellyfin.yaml
EOF
chmod 0600 /etc/htpc/htpc.env

TORBOX_PASS_OBSCURED=""
if command -v rclone >/dev/null 2>&1; then
  TORBOX_PASS_OBSCURED="$(rclone obscure "$TORBOX_PASS")"
else
  TORBOX_PASS_OBSCURED="$(docker run --rm ghcr.io/rclone/rclone:latest obscure "$TORBOX_PASS")"
fi

cat >"$HTPC_HOME/rclone/rclone.conf" <<EOF
[zurghttp]
type = webdav
url = http://zurg:9999/dav
vendor = other
pacer_min_sleep = 0

[torbox]
type = webdav
url = https://webdav.torbox.app
vendor = other
user = $TORBOX_USER
pass = $TORBOX_PASS_OBSCURED
EOF

if [[ -f "$REPO_ROOT/config/zurg.yaml" ]]; then
  sed "s/^token:.*$/token: $RD_API_KEY/" "$REPO_ROOT/config/zurg.yaml" >"$HTPC_HOME/zurg/config.yaml"
else
  cat >"$HTPC_HOME/zurg/config.yaml" <<EOF
zurg: v1
token: $RD_API_KEY
host: "[::]"
port: 9999
EOF
fi

install -m 0755 "$REPO_ROOT/services/htpc-reset-rclone-mounts.sh" /usr/local/bin/htpc-reset-rclone-mounts

mkdir -p /etc/systemd/system
install -m 0644 "$REPO_ROOT/services/systemd/htpc-reset-rclone-mounts.service" /etc/systemd/system/htpc-reset-rclone-mounts.service

systemctl daemon-reload
systemctl enable htpc-reset-rclone-mounts.service

echo "Bringing up stack..."
docker compose --env-file "$REPO_ROOT/docker/.htpc.env" -f "$REPO_ROOT/docker/htpc jellyfin.yaml" up -d

echo "Running mount reset once..."
/usr/local/bin/htpc-reset-rclone-mounts

echo "Done."
