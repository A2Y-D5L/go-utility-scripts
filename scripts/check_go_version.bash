#!/usr/bin/env bash
# Check if the locally installed Go toolchain matches the latest stable release.
# - Prints a clear status message.
# - Exit codes:
#     0 = Up to date
#     2 = Update available (local is older than latest)
#     3 = Local is newer than latest (e.g., devel/nightly) or cannot determine reliably
#     4 = Network error while determining latest
#     5 = Go not installed
#     6 = Unexpected parsing error
# - No external JSON tools required. Uses curl (or wget fallback).

set -euo pipefail

log() { printf '%s\n' "$*" >&2; }
export log

have() { command -v "$1" >/dev/null 2>&1; }
export have

fetch() {
  # Fetch URL to stdout using curl or wget. Returns non-zero on failure.
  # Uses timeouts and follows redirects.
  local url=$1
  if have curl; then
    # -f: fail on HTTP errors; -L: follow redirects; --max-time: hard timeout
    curl -fsSL --max-time 15 "$url"
  elif have wget; then
    # -q: quiet; -O-: stdout; --timeout: seconds; --max-redirect: 5
    wget -q -O- --timeout=15 --max-redirect=5 "$url"
  else
    log "Error: neither 'curl' nor 'wget' found."
    return 127
  fi
}
export fetch

trim() { sed -e 's/^[[:space:]]\+//' -e 's/[[:space:]]\+$//'; }
export trim

# Compare two Go-style semantic versions (e.g., "1.22.5" vs "1.21.11").
# Prints -1 if a<b, 0 if a==b, 1 if a>b. Returns 0 always.
vercmp() {
  # Normalize: ensure three numeric fields (major.minor.patch)
  local a b
  a=$1 b=$2

  # Strip any suffix after a hyphen (e.g., "1.23.0-rc1" -> "1.23.0")
  a=${a%%-*}
  b=${b%%-*}

  # Split by '.'
  local IFS=.
  # shellcheck disable=SC2206
  local A=($a) B=($b)
  # Pad to length 3 with zeros
  while ((${#A[@]}<3)); do A+=("0"); done
  while ((${#B[@]}<3)); do B+=("0"); done
  # Numeric compare field by field
  for i in 0 1 2; do
    local ai=${A[$i]:-0} bi=${B[$i]:-0}
    # Guard non-numeric (shouldn't happen for stable releases)
    [[ $ai =~ ^[0-9]+$ ]] || ai=0
    [[ $bi =~ ^[0-9]+$ ]] || bi=0
    if ((ai<bi)); then printf '%s\n' -1; return 0; fi
    if ((ai>bi)); then printf '%s\n' 1; return 0; fi
  done
  printf '%s\n' 0
}
export vercmp

# Extract "goX.Y[.Z]" from "go version" output. Returns empty on failure.
local_goversion() { 
  if ! have go; then
    return 1
  fi
  go version 2>/dev/null | awk '{print $3}' || return 1
}
export local_goversion

# Parse "goX.Y[.Z]" into "X.Y[.Z]" (strip "go" prefix).
strip_go_prefix() { sed -E 's/^go//'; }
export strip_go_prefix

# Determine latest stable Go version string like "go1.22.5".
# Strategy:
#   1) https://go.dev/VERSION?m=text (authoritative stable; returns e.g. "go1.22.5")
#   2) Fallback: https://go.dev/dl/?mode=json&include=all (pick first non-rc/beta)
latest_goversion() {
  local v
  # Primary source
  if v=$(fetch "https://go.dev/VERSION?m=text" | trim 2>/dev/null); then
    # Expect "go1.X.Y" and not beta/rc
    if printf '%s' "$v" | grep -E -qi '^go[0-9]+\.[0-9]+(\.[0-9]+)?$'; then
      printf '%s\n' "$v"
      return 0
    fi
  fi

  # Fallback to JSON list (avoid requiring jq)
  # We grab the first occurrence of a "version":"goX.Y(.Z)?" that is NOT rc/beta.
  if v=$(fetch "https://go.dev/dl/?mode=json&include=all" 2>/dev/null \
      | tr -d '\n' \
      | grep -oE '"version"[[:space:]]*:[[:space:]]*"go[0-9]+\.[0-9]+(\.[0-9]+)?(-[a-z0-9]+)?"' \
      | sed -E 's/^"version"[[:space:]]*:[[:space:]]*"([^"]+)".*$/\1/' \
      | grep -Ev -- '-rc|-beta' \
      | head -n1); then
    if [ -n "$v" ]; then
      printf '%s\n' "$v"
      return 0
    fi
  fi

  return 1
}
export latest_goversion

# Main execution logic - only run if script is executed directly
main() {
  local local_ver latest_ver local_clean latest_clean cmp_result
  
  # Check if Go is installed
  if ! have go; then
    log "Error: Go is not installed or not in PATH"
    return 5
  fi
  
  # Get local Go version
  if ! local_ver=$(local_goversion); then
    log "Error: Could not determine local Go version"
    return 6
  fi
  
  if [ -z "$local_ver" ]; then
    log "Error: Local Go version string is empty"
    return 6
  fi
  
  # Get latest stable Go version
  if ! latest_ver=$(latest_goversion); then
    log "Error: Could not determine latest Go version (network error)"
    return 4
  fi
  
  # Strip "go" prefix for comparison
  local_clean=$(printf '%s' "$local_ver" | strip_go_prefix)
  latest_clean=$(printf '%s' "$latest_ver" | strip_go_prefix)
  
  # Compare versions
  cmp_result=$(vercmp "$local_clean" "$latest_clean")
  
  case $cmp_result in
    -1)
      log "Update available: $local_ver → $latest_ver"
      return 2
      ;;
    0)
      log "Up to date: $local_ver"
      return 0
      ;;
    1)
      log "Local version newer than latest stable: $local_ver (latest: $latest_ver)"
      return 3
      ;;
    *)
      log "Error: Unexpected version comparison result: $cmp_result"
      return 6
      ;;
  esac
}

# Only execute main if script is run directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi