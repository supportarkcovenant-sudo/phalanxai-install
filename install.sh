#!/usr/bin/env bash
# Guided install of PhalanxAI on a Linux or macOS host.
#
# Piped from the web (curl -fsSL <url> | bash) it pulls the published image. Run from a
# checkout of the source repository (bash install.sh) it builds the image from that source.
# Options: see usage() below, or --help.
set -euo pipefail

# === Constants ===
LOCAL_IMAGE="phalanxai:0.4.2"
REGISTRY_IMAGE="ghcr.io/supportarkcovenant-sudo/phalanxai:latest"
# Where the image keeps the host command and its completion (see Dockerfile).
IMAGE_HOST_FILES_DIR="/opt/phalanx/deploy"
DOCKER_INSTALL_URL="https://get.docker.com"

# Empty when the script is piped into bash: there is no checkout next to it then.
SCRIPT_SOURCE="${BASH_SOURCE[0]:-}"
SCRIPT_DIR=""
if [ -n "$SCRIPT_SOURCE" ] && [ -f "$SCRIPT_SOURCE" ]; then
  SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_SOURCE")" && pwd)"
fi
INSTALL_DIR="/opt/phalanxai"
BIN_DIR="/usr/local/bin"
IMAGE=""
INSTALL_DOCKER=0
DOCKER_JUST_INSTALLED=0
HOST_FILES_DIR=""
PORT="8765"
BIND="0.0.0.0"
HOST_ACCESS=""
TLS=""
# Comma-separated addresses or networks of reverse proxies whose forwarded headers are believed.
TRUSTED_PROXIES=""
# Path the app is served under behind a reverse proxy ("/phalanx"); empty for a hostname of its own.
BASE_PATH=""
ASSUME_YES=0
START=1
FOLDERS=()
READY_TIMEOUT_SECONDS=60

say() { printf '%s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }
die() { printf 'install: %s\n' "$*" >&2; exit 1; }

as_root() { if [ "$(id -u)" = "0" ]; then "$@"; else sudo "$@"; fi; }

from_checkout() { [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/Dockerfile" ]; }

usage() {
  cat <<'EOF'
Guided install of PhalanxAI on a Linux or macOS host.

  install.sh                  ask questions (folder paths complete with Tab)
  install.sh --yes --folder /srv/projects [--folder ...] [--port 8765]
             [--bind 0.0.0.0] [--host-access full|restricted] [--tls off|self-signed]
             [--trusted-proxy ADDRESS_OR_NETWORK ...] [--base-path /phalanx]
             [--install-dir DIR] [--bin-dir DIR] [--image NAME] [--install-docker] [--no-start]

--trusted-proxy names a reverse proxy (nginx) in front of PhalanxAI, for example 172.16.0.0/12
for one reaching it through Docker. A proxy on this machine's 127.0.0.1 is always trusted.
--base-path is for a proxy that serves PhalanxAI under a path of another site (example.com/phalanx/).

Piped from the web, options go after "bash -s --":
  curl -fsSL <url> | bash -s -- --yes --folder /srv/projects
EOF
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --yes|-y) ASSUME_YES=1 ;;
      --folder) FOLDERS+=("${2:?--folder needs a path}"); shift ;;
      --port) PORT="${2:?--port needs a number}"; shift ;;
      --bind) BIND="${2:?--bind needs an address}"; shift ;;
      --host-access) HOST_ACCESS="${2:?--host-access needs full or restricted}"; shift ;;
      --tls) TLS="${2:?--tls needs off or self-signed}"; shift ;;
      --base-path) BASE_PATH="${2:?--base-path needs a path such as /phalanx}"; shift ;;
      --trusted-proxy) TRUSTED_PROXIES="${TRUSTED_PROXIES:+$TRUSTED_PROXIES,}${2:?--trusted-proxy needs an address or network}"; shift ;;
      --install-dir) INSTALL_DIR="${2:?}"; shift ;;
      --bin-dir) BIN_DIR="${2:?}"; shift ;;
      --image) IMAGE="${2:?}"; shift ;;
      --install-docker) INSTALL_DOCKER=1 ;;
      --no-start) START=0 ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown option: $1" ;;
    esac
    shift
  done
}

# Reuse the answers from an earlier install as the defaults.
load_previous() {
  [ -f "$INSTALL_DIR/phalanx.env" ] || return 0
  # shellcheck disable=SC1091
  . "$INSTALL_DIR/phalanx.env"
  PORT="${PHALANX_PORT:-$PORT}"; BIND="${PHALANX_BIND:-$BIND}"
  [ -n "$HOST_ACCESS" ] || HOST_ACCESS="${PHALANX_HOST_ACCESS:-}"
  [ -n "$TLS" ] || TLS="${PHALANX_TLS:-}"
  [ -n "$TRUSTED_PROXIES" ] || TRUSTED_PROXIES="${PHALANX_TRUSTED_PROXIES:-}"
  [ -n "$BASE_PATH" ] || BASE_PATH="${PHALANX_BASE_PATH:-}"
  if [ "${#FOLDERS[@]}" -eq 0 ] && [ -f "$INSTALL_DIR/mounts.list" ]; then
    while IFS= read -r folder; do [ -n "$folder" ] && FOLDERS+=("$folder"); done < "$INSTALL_DIR/mounts.list"
    PREVIOUS_FOLDERS=1
  fi
}

# Piped in (curl | bash), stdin is this script, so questions are asked on the terminal instead.
attach_terminal() {
  [ "$ASSUME_YES" = "1" ] && return 0
  [ -t 0 ] && return 0
  { : </dev/tty; } 2>/dev/null || die "no terminal to ask questions on. Rerun with --yes and options (see --help)."
  exec </dev/tty
}

choose_image() {
  [ -n "$IMAGE" ] && return 0
  if from_checkout; then IMAGE="$LOCAL_IMAGE"; else IMAGE="$REGISTRY_IMAGE"; fi
}

confirm_docker_install() {
  [ "$INSTALL_DOCKER" = "1" ] && return 0
  [ "$ASSUME_YES" = "1" ] && die "Docker is not installed. Add --install-docker to have it installed, or install Docker Engine first."
  read -r -p "Docker is not installed. Install it now with Docker's own script ($DOCKER_INSTALL_URL)? [Y/n] " answer
  [[ "$answer" =~ ^[Nn] ]] && die "PhalanxAI needs Docker. Install Docker Engine, then run this again."
  return 0
}

install_docker() {
  [ "$(uname -s)" = "Linux" ] || die "Docker is not installed. Install Docker Desktop first."
  command -v curl >/dev/null || die "Docker is not installed, and curl is needed to install it."
  confirm_docker_install
  step "Installing Docker"
  local script
  script="$(mktemp)"
  curl -fsSL "$DOCKER_INSTALL_URL" -o "$script" || die "could not download $DOCKER_INSTALL_URL"
  as_root sh "$script"
  rm -f "$script"
  [ "$(id -u)" = "0" ] || as_root usermod -aG docker "$(id -un)"
  DOCKER_JUST_INSTALLED=1
}

preflight() {
  step "Checking this machine"
  command -v docker >/dev/null || install_docker
  if ! docker info >/dev/null 2>&1; then
    # A new group membership only reaches shells started after it was granted.
    [ "$DOCKER_JUST_INSTALLED" = "1" ] && die "Docker is installed, but this shell cannot use it yet. Log out and back in (or start Docker), then run this again."
    die "Docker is installed but this user cannot use it. Start Docker, or add this user to the 'docker' group."
  fi
  docker compose version >/dev/null 2>&1 || die "The Docker Compose plugin is missing (docker compose)."
  say "Docker $(docker version --format '{{.Server.Version}}') and Compose are ready."
}

choose_host_access() {
  if [ "$(uname -s)" != "Linux" ]; then
    [ "$HOST_ACCESS" = "full" ] && say "Full host access is only possible on Linux; using restricted."
    HOST_ACCESS="restricted"
    return
  fi
  [ -n "$HOST_ACCESS" ] && return
  HOST_ACCESS="full"
  [ "$ASSUME_YES" = "1" ] && return
  step "Host access"
  say "Full:       Claude Code sessions can run any command on this host (host-exec) and see every file."
  say "Restricted: sessions see only the folders you choose, plus Docker."
  read -r -p "Give PhalanxAI full host access? [Y/n] " answer
  [[ "$answer" =~ ^[Nn] ]] && HOST_ACCESS="restricted"
  return 0
}

# Absolute form of a path that may not exist. `realpath -m` is GNU-only, and macOS ships the BSD one.
absolute_path() {
  local path="$1"
  [ "${path#/}" != "$path" ] || path="$PWD/$path"
  if [ -d "$path" ]; then (cd "$path" && pwd -P); else printf '%s
' "${path%/}"; fi
}

add_folder() {
  local folder="${1/#\~/$HOME}"
  folder="$(absolute_path "$folder")"
  [ -d "$folder" ] || { say "  Not a folder: $folder"; return 1; }
  local existing
  for existing in "${FOLDERS[@]:-}"; do [ "$existing" = "$folder" ] && { say "  Already added: $folder"; return 0; }; done
  FOLDERS+=("$folder")
  local repos
  repos="$(find "$folder" -mindepth 2 -maxdepth 2 -name .git -type d 2>/dev/null | sed 's|/\.git$||' | sort | head -n 8)"
  say "  Added $folder"
  [ -n "$repos" ] && say "$(printf '%s\n' "$repos" | sed 's|^|    contains repository: |')"
  return 0
}

choose_folders() {
  local given=("${FOLDERS[@]:-}")
  FOLDERS=()
  local folder
  for folder in "${given[@]}"; do [ -n "$folder" ] && { add_folder "$folder" || [ "${PREVIOUS_FOLDERS:-0}" = "1" ] || die "folder does not exist: $folder"; }; done
  [ "$ASSUME_YES" = "1" ] && return 0
  step "Project folders"
  say "Folders Claude Code may work in. Each one appears inside PhalanxAI at the same path."
  say "Type a path (Tab completes it) and press Enter. Leave it empty when you are done."
  while true; do
    # -e turns on readline, which gives Tab completion of paths on this host.
    read -e -r -p "Folder: " folder || break
    [ -z "$folder" ] && break
    add_folder "$folder" || true
  done
}

choose_network() {
  [ "$ASSUME_YES" = "1" ] && return 0
  step "Network"
  read -r -p "Port for the web UI [$PORT]: " answer; PORT="${answer:-$PORT}"
  say "Listen on 0.0.0.0 to reach it from other machines on your network, or 127.0.0.1 for this machine only."
  read -r -p "Listen address [$BIND]: " answer; BIND="${answer:-$BIND}"
  [ "$BIND" = "127.0.0.1" ] && return 0
  say "Without encryption, your password and terminal traffic cross the network in clear text."
  say "With it, PhalanxAI makes its own certificate and browsers warn once before you accept it."
  local default_answer="y/N"; [ "$TLS" = "self-signed" ] && default_answer="Y/n"
  read -r -p "Encrypt with HTTPS (self-signed certificate)? [$default_answer] " answer
  case "$answer" in [Yy]*) TLS="self-signed" ;; [Nn]*) TLS="off" ;; esac
}

validate() {
  [[ "$PORT" =~ ^[0-9]+$ ]] && [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || die "port must be a number from 1 to 65535"
  [ "$HOST_ACCESS" = "full" ] || [ "$HOST_ACCESS" = "restricted" ] || die "--host-access must be full or restricted"
  TLS="${TLS:-off}"
  [ "$TLS" = "off" ] || [ "$TLS" = "self-signed" ] || die "--tls must be off or self-signed (for your own certificate, see README)"
  [ "${#FOLDERS[@]}" -gt 0 ] || say "No project folders chosen. Add some later with: phalanx mounts add <folder>"
}

build_image() {
  if docker image inspect "$IMAGE" >/dev/null 2>&1; then
    say "Using existing image $IMAGE."
    return
  fi
  say "Building $IMAGE (a few minutes the first time)..."
  docker build -t "$IMAGE" "$SCRIPT_DIR"
}

pull_image() {
  say "Pulling $IMAGE..."
  docker pull "$IMAGE" && return 0
  docker image inspect "$IMAGE" >/dev/null 2>&1 || die "could not pull $IMAGE, and there is no copy of it on this machine"
  say "Could not pull $IMAGE; using the copy already on this machine."
}

ensure_image() {
  step "Container image"
  if from_checkout; then build_image; else pull_image; fi
}

# The host command and its completion: from the checkout, or out of the image when there is none.
fetch_host_files() {
  if from_checkout; then
    HOST_FILES_DIR="$SCRIPT_DIR/deploy"
    return 0
  fi
  HOST_FILES_DIR="$(mktemp -d)"
  local name
  for name in phalanx phalanx-completion.bash; do
    docker run --rm --entrypoint cat "$IMAGE" "$IMAGE_HOST_FILES_DIR/$name" > "$HOST_FILES_DIR/$name" \
      || die "image $IMAGE does not carry $name (it predates the one-line installer)"
  done
}

write_files() {
  step "Installing into $INSTALL_DIR"
  as_root mkdir -p "$INSTALL_DIR" "$BIN_DIR"
  as_root chown "$(id -u):$(id -g)" "$INSTALL_DIR"
  cat > "$INSTALL_DIR/phalanx.env" <<EOF
PHALANX_IMAGE="$IMAGE"
PHALANX_PORT="$PORT"
PHALANX_BIND="$BIND"
PHALANX_HOST_ACCESS="$HOST_ACCESS"
PHALANX_TLS="$TLS"
PHALANX_TRUSTED_PROXIES="$TRUSTED_PROXIES"
PHALANX_BASE_PATH="$BASE_PATH"
PHALANX_UID="$(id -u)"
PHALANX_GID="$(id -g)"
EOF
  printf '%s\n' "${FOLDERS[@]:-}" | sed '/^$/d' > "$INSTALL_DIR/mounts.list"
  as_root install -m 0755 "$HOST_FILES_DIR/phalanx" "$BIN_DIR/phalanx"
  if [ -d /etc/bash_completion.d ]; then
    as_root install -m 0644 "$HOST_FILES_DIR/phalanx-completion.bash" /etc/bash_completion.d/phalanx
  fi
  PHALANX_INSTALL_DIR="$INSTALL_DIR" "$BIN_DIR/phalanx" render
  say "Wrote phalanx.env, mounts.list, compose.yaml, and the 'phalanx' command ($BIN_DIR/phalanx)."
}

start_and_report() {
  [ "$START" = "1" ] || { say "Not starting (--no-start). Start it with: phalanx up"; return 0; }
  step "Starting PhalanxAI"
  export PHALANX_INSTALL_DIR="$INSTALL_DIR"
  "$BIN_DIR/phalanx" up
  local waited=0 container scheme="http"
  container="$("$BIN_DIR/phalanx" container-name)"
  [ "$TLS" = "off" ] || scheme="https"
  # -k: this only asks "is it up"; the certificate is the app's own, made a moment ago.
  until docker exec "$container" curl -fsSk "$scheme://127.0.0.1:$PORT/api/v1/system/version" >/dev/null 2>&1; do
    waited=$((waited + 1))
    [ "$waited" -lt "$READY_TIMEOUT_SECONDS" ] || die "PhalanxAI did not answer within ${READY_TIMEOUT_SECONDS}s. See: phalanx logs"
    sleep 1
  done
  step "PhalanxAI is running"
  say "Open in a browser:"
  "$BIN_DIR/phalanx" url | sed 's/^/  /'
  say "Setup token (asked once, when you set the web password):"
  "$BIN_DIR/phalanx" setup-token | sed 's/^/  /'
  say ""
  say "Next:"
  say "  phalanx login            sign in to Claude Code (Claude Code's own sign-in)"
  say "  phalanx project add DIR  register a project in one of your folders"
  say "  phalanx claude           open Claude Code in the current project"
  if [ "$ASSUME_YES" != "1" ] && [ -t 0 ]; then
    read -r -p "Sign in to Claude Code now? [Y/n] " answer
    [[ "$answer" =~ ^[Nn] ]] || "$BIN_DIR/phalanx" login
  fi
}

main() {
  parse_args "$@"
  attach_terminal
  choose_image
  load_previous
  preflight
  choose_host_access
  choose_folders
  choose_network
  validate
  ensure_image
  fetch_host_files
  write_files
  start_and_report
}

# One line on purpose: once questions come from the terminal, bash can read no more of a piped script.
main "$@"; exit
