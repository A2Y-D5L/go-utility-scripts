#!/usr/bin/env bash
# ensure_latest_go.bash
#
# Ensures the latest stable Go is installed, using functions from ./check_go_version.bash.
# Behavior:
#   - Sources ./check_go_version.bash to reuse network + parsing functions.
#   - Detects OS/arch and downloads the correct installer (pkg on macOS, tarball on Linux).
#   - Verifies SHA-256 checksum before installing.
#   - Installs/updates Go, then verifies the installed version matches the latest stable.
#
# Exit codes:
#   0 = Already up to date or successfully updated
#   1 = Usage error / environment issue (missing files, unsupported OS/arch)
#   2 = Network/download error
#   3 = Checksum verification failed
#   4 = Install error
#   5 = Post-install verification mismatch

set -euo pipefail

# ------------------------------ Config ------------------------------

# Default to same directory as this script, fallback to current directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK_SCRIPT="${CHECK_SCRIPT:-${SCRIPT_DIR}/check_go_version.bash}"  # Path to the checker script

# ------------------------------ Helpers -----------------------------

log() {
  # If QUIET=1, suppress non-error messages (anything not starting with "Error:")
  if [[ "${QUIET:-0}" == "1" ]]; then
    [[ "$*" == Error:* ]] || return 0
  fi
  printf '%s\n' "$*" >&2
}

have() { command -v "$1" >/dev/null 2>&1; }

need_cmd() {
  if ! have "$1"; then
    log "Error: required command not found: $1"
    exit 1
  fi
}

detect_os_arch() {
  # Sets two globals: GO_OS and GO_ARCH matching Go download naming.
  local uname_s uname_m
  uname_s=$(uname -s 2>/dev/null || echo "unknown")
  uname_m=$(uname -m 2>/dev/null || echo "unknown")

  case "$uname_s" in
    Darwin) GO_OS="darwin" ;;
    Linux)  GO_OS="linux" ;;
    *)
      log "Error: unsupported OS: $uname_s"
      exit 1
      ;;
  esac

  case "$uname_m" in
    x86_64|amd64)   GO_ARCH="amd64" ;;
    arm64|aarch64)  GO_ARCH="arm64" ;;
    riscv64)        GO_ARCH="riscv64" ;;
    ppc64le)        GO_ARCH="ppc64le" ;;
    *)
      log "Error: unsupported architecture: $uname_m"
      exit 1
      ;;
  esac
}

fetch() {
  # Fetch URL to stdout using curl or wget, with timeouts and redirects.
  local url=$1
  if have curl; then
    curl -fsSL --max-time 60 "$url"
  elif have wget; then
    wget -q -O- --timeout=60 --max-redirect=5 "$url"
  else
    log "Error: neither 'curl' nor 'wget' found."
    return 127
  fi
}

download_to() {
  # download_to <url> <dest_file>
  local url=$1 dest=$2
  if have curl; then
    curl -fL --connect-timeout 15 --max-time 600 -o "$dest" "$url"
  else
    wget -O "$dest" --timeout=600 --max-redirect=5 "$url"
  fi
}

sha256_file() {
  # sha256_file <file> -> prints hex checksum
  local f=$1
  if have sha256sum; then
    sha256sum "$f" | awk '{print $1}'
  elif have shasum; then
    shasum -a 256 "$f" | awk '{print $1}'
  else
    log "Error: need 'sha256sum' or 'shasum' for checksum verification"
    exit 1
  fi
}

# --------------------------- Pre-flight -----------------------------

# Check for required commands early
need_cmd uname
need_cmd mkdir
need_cmd rm
if ! have curl && ! have wget; then
  log "Error: either 'curl' or 'wget' is required for downloads"
  exit 1
fi
if ! have sha256sum && ! have shasum; then
  log "Error: either 'sha256sum' or 'shasum' is required for checksum verification"
  exit 1
fi

# Scoped helpers to avoid clobbering this script's functions when using the checker
latest_from_checker() { ( . "$CHECK_SCRIPT"; latest_goversion ); }
strip_from_checker()  { ( . "$CHECK_SCRIPT"; strip_go_prefix ); }
local_from_checker()  { ( . "$CHECK_SCRIPT"; command -v local_goversion >/dev/null 2>&1 && local_goversion ); }

# 2) Determine current status using the checker script's "main" for exit codes
CHECK_OUTPUT=""
CHECK_STATUS=0
if OUTPUT="$("$CHECK_SCRIPT" 2>&1)"; then
  CHECK_OUTPUT="$OUTPUT"; CHECK_STATUS=0
else
  CHECK_STATUS=$?; CHECK_OUTPUT="$OUTPUT"
fi

# 3) Get latest version string (e.g., "go1.23.1")
LATEST_RAW=""
if ! LATEST_RAW="$(latest_from_checker)"; then
  log "Error: failed to determine latest Go version (network error)"
  exit 2
fi
# Some checkers may include extra fields (e.g., timestamps). Extract just the version token.
LATEST_RAW="$(printf '%s' "$LATEST_RAW" | tr -d '\r' | grep -Eo 'go[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1)"
if [[ -z "$LATEST_RAW" ]]; then
  log "Error: failed to parse latest Go version from checker output"
  exit 2
fi
LATEST_NUM="$(printf '%s' "$LATEST_RAW" | strip_from_checker)"

# 4) Parse local version if present (best-effort)
LOCAL_RAW=""
if have go; then
  # Use the checker's local_goversion if present; otherwise fall back to `go version`
  LOCAL_RAW="$(local_from_checker || go version 2>/dev/null | grep -Eo 'go[0-9]+\.[0-9]+(\.[0-9]+)?(-[A-Za-z0-9._-]+)?' | head -n1 || true)"
fi
LOCAL_NUM=""
if [[ -n "${LOCAL_RAW:-}" ]]; then
  LOCAL_NUM="$(printf '%s' "$LOCAL_RAW" | strip_from_checker)"
fi

# 5) Early exits based on checker status
case "$CHECK_STATUS" in
  0)
    log "Go is already up to date ($LOCAL_RAW). Nothing to do."
    exit 0
    ;;
  3)
    log "Local Go appears newer/pre-release ($LOCAL_RAW) than latest stable ($LATEST_RAW). No action taken."
    exit 0
    ;;
  4)
    log "Warning from checker: network issue determining latest. We resolved LATEST as $LATEST_RAW independently, proceeding."
    ;;
  5)
    log "Go not detected locally. Will install latest: $LATEST_RAW"
    ;;
  2)
    log "Update available: $LOCAL_RAW → $LATEST_RAW"
    ;;
  6)
    log "Checker returned parsing error. Proceeding to install/repair to $LATEST_RAW."
    ;;
  *)
    # Any unexpected code: proceed carefully if we have LATEST
    log "Checker returned unexpected status ($CHECK_STATUS). Proceeding to ensure $LATEST_RAW is installed."
    [[ -n "$CHECK_OUTPUT" ]] && log "Note: checker output: $CHECK_OUTPUT"
    ;;
esac

# Extract a leading 64-hex SHA from input
extract_sha() {
  grep -Eo '^[a-f0-9]{64}' | head -n1
}

# Try to fetch a checksum from a URL and return just the 64-hex digest
fetch_sha_from_url() {
  local url="$1"
  local body
  body=$(fetch "$url" 2>/dev/null || true)
  [[ -z "$body" ]] && return 1
  printf '%s' "$body" | extract_sha
}

# ------------------------------ Install -----------------------------

need_cmd tar # required for Linux tarball installs; macOS path uses pkg

detect_os_arch

ensure_root_prefix() {
  if have sudo || [[ $EUID -eq 0 ]]; then
    INSTALL_PREFIX="/usr/local"
    if have sudo && [[ $EUID -ne 0 ]]; then
      USE_SUDO="sudo"
    else
      USE_SUDO=""
    fi
  else
    INSTALL_PREFIX="${GO_PREFIX:-$HOME/.local}"
    USE_SUDO=""
    mkdir -p "$INSTALL_PREFIX" || { log "Error: cannot create $INSTALL_PREFIX"; exit 4; }
    log "No sudo available. Will install to $INSTALL_PREFIX/go"
  fi
}

ensure_root_prefix
INSTALL_DIR="$INSTALL_PREFIX/go"
INSTALL_BIN="$INSTALL_DIR/bin/go"

if [[ "$GO_OS" == "darwin" ]]; then
  if have brew && brew list --versions go >/dev/null 2>&1; then
    log "Detected Homebrew Go. Consider: brew upgrade go  (or set FORCE_DIRECT_INSTALL=1 to proceed with a direct install)."
    [[ "${FORCE_DIRECT_INSTALL:-0}" == 1 ]] || exit 1
  fi
  if have asdf && asdf plugin-list 2>/dev/null | grep -q "^golang$"; then
    if asdf list golang >/dev/null 2>&1; then
      log "Detected asdf-managed Go. Consider: asdf install golang latest && asdf global golang latest  (or set FORCE_DIRECT_INSTALL=1)."
      [[ "${FORCE_DIRECT_INSTALL:-0}" == 1 ]] || exit 1
    fi
  fi
fi

BASE_URL="https://go.dev/dl"

if [[ "$GO_OS" == "darwin" ]]; then
  if [[ -n "$USE_SUDO" || $EUID -eq 0 ]]; then
    EXT="pkg"
    ART_NAME="${LATEST_RAW}.${GO_OS}-${GO_ARCH}.${EXT}"
    INSTALL_METHOD="pkg"
  else
    EXT="tar.gz"
    ART_NAME="${LATEST_RAW}.${GO_OS}-${GO_ARCH}.${EXT}"
    INSTALL_METHOD="tar"
  fi
elif [[ "$GO_OS" == "linux" ]]; then
  EXT="tar.gz"
  ART_NAME="${LATEST_RAW}.${GO_OS}-${GO_ARCH}.${EXT}"
  INSTALL_METHOD="tar"
else
  log "Error: unsupported OS for installer construction: $GO_OS"
  exit 1
fi

ART_URL="${BASE_URL}/${ART_NAME}"
SHA_URL="${ART_URL}.sha256"

if [[ "${DRY_RUN:-0}" == "1" ]]; then
  log "[DRY RUN] Would download: $ART_URL"
  log "[DRY RUN] Would fetch checksum: $SHA_URL"
  log "[DRY RUN] Would install via: $INSTALL_METHOD into $INSTALL_DIR"
  log "[DRY RUN] Would ensure PATH includes: $INSTALL_DIR/bin"
  exit 0
fi

# Prepare temp workspace
TMPDIR=$(mktemp -d 2>/dev/null || mktemp -d -t goinst)
trap 'rm -rf "$TMPDIR"' EXIT

log "Downloading: ${ART_URL}"
download_to "$ART_URL" "$TMPDIR/$ART_NAME" || { log "Error: failed to download $ART_NAME"; exit 2; }

log "Fetching checksum: ${SHA_URL}"
EXPECTED_SHA="$(fetch_sha_from_url "$SHA_URL" || true)"

# If the primary host returns HTML or anything non-SHA, fall back to well-known mirrors
if [[ -z "$EXPECTED_SHA" ]]; then
  ALT1="https://dl.google.com/go/${ART_NAME}.sha256"
  ALT2="https://storage.googleapis.com/golang/${ART_NAME}.sha256"
  log "Primary checksum fetch returned unexpected content. Trying: $ALT1"
  EXPECTED_SHA="$(fetch_sha_from_url "$ALT1" || true)"
  if [[ -z "$EXPECTED_SHA" ]]; then
    log "Fallback #1 failed. Trying: $ALT2"
    EXPECTED_SHA="$(fetch_sha_from_url "$ALT2" || true)"
  fi
fi

if [[ -z "$EXPECTED_SHA" ]]; then
  log "Error: unable to obtain a valid SHA256 for $ART_NAME from any source"
  exit 2
fi

ACTUAL_SHA=$(sha256_file "$TMPDIR/$ART_NAME")

if [[ "$EXPECTED_SHA" != "$ACTUAL_SHA" ]]; then
  log "Error: checksum verification failed for $ART_NAME"
  log "Expected: $EXPECTED_SHA"
  log "Actual:   $ACTUAL_SHA"
  exit 3
fi
log "Checksum verified."

# Perform install per-platform
if [[ "$GO_OS" == "darwin" && "$INSTALL_METHOD" == "pkg" ]]; then
  need_cmd installer
  if [[ -z "$USE_SUDO" && $EUID -ne 0 ]]; then
    log "Error: pkg install requires sudo or root"
    exit 4
  fi
  log "Installing Go with installer: $ART_NAME (may prompt for sudo)"
  if ! ${USE_SUDO:+$USE_SUDO }installer -pkg "$TMPDIR/$ART_NAME" -target / >/dev/null; then
    log "Error: pkg installation failed"
    exit 4
  fi
  # On pkg installs, the destination is typically /usr/local/go; reflect that in variables
  INSTALL_PREFIX="/usr/local"
  INSTALL_DIR="$INSTALL_PREFIX/go"
  INSTALL_BIN="$INSTALL_DIR/bin/go"
else
  # Tarball path (Linux or macOS user-space)
  need_cmd tar
  log "Installing Go tarball to $INSTALL_PREFIX (may prompt for sudo)"
  if [[ -d "$INSTALL_DIR" ]]; then
    log "Removing existing $INSTALL_DIR"
    ${USE_SUDO:+$USE_SUDO }rm -rf "$INSTALL_DIR"
  fi
  if ! ${USE_SUDO:+$USE_SUDO }tar --no-same-owner -C "$INSTALL_PREFIX" -xzf "$TMPDIR/$ART_NAME"; then
    log "Error: extraction failed"
    exit 4
  fi
  # Ensure PATH for this session includes the install
  case ":$PATH:" in
    *:"$INSTALL_DIR/bin":*) ;;
    *) export PATH="$INSTALL_DIR/bin:$PATH"; log "Added $INSTALL_DIR/bin to PATH for this session" ;;
  esac
fi

# ------------------------ Post-install verify -----------------------

# Verify the just-installed binary directly first
if [[ ! -x "$INSTALL_BIN" ]]; then
  log "Error: expected installed binary not found at $INSTALL_BIN"
  exit 5
fi

if ! INSTALLED_RAW="$("$INSTALL_BIN" version 2>/dev/null | grep -Eo 'go[0-9]+\.[0-9]+(\.[0-9]+)?(-[A-Za-z0-9._-]+)?' | head -n1)"; then
  log "Error: could not parse '$INSTALL_BIN version' output after installation"
  log "Raw output: $("$INSTALL_BIN" version 2>&1 || echo 'go version failed')"
  exit 5
fi

if [[ -z "$INSTALLED_RAW" ]]; then
  log "Error: post-install could not read Go version"
  exit 5
fi

INSTALLED_NUM="$(printf '%s' "$INSTALLED_RAW" | strip_from_checker)"

if [[ "$INSTALLED_NUM" != "$LATEST_NUM" ]]; then
  log "Error: installed Go ($INSTALLED_RAW) != expected ($LATEST_RAW)"
  log "PATH order may prefer a different Go. Binaries found:"
  command -v -a go || true
  exit 5
fi

log "Go is now up to date: $INSTALLED_RAW"

# Optional: tell the user if their shell resolves to a different go first
RESOLVED_GO="$(command -v go 2>/dev/null || true)"
if [[ -n "$RESOLVED_GO" && "$RESOLVED_GO" != "$INSTALL_BIN" ]]; then
  log "Note: Your shell resolves 'go' to $RESOLVED_GO, not $INSTALL_BIN. Consider adjusting PATH."
fi