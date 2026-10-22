# shellcheck shell=bash
SO_VERSION="1.0.0"
UROOT=${SYSOPS_ROOT:-}                                   # alternate root for user management (tests, image building)
STATE=${SYSOPS_STATE:-$([[ $EUID -eq 0 ]] && echo /var/lib/sysops || echo "$HOME/.local/state/sysops")}
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then RED=$'\e[31m'; GRN=$'\e[32m'; YEL=$'\e[33m'; BLU=$'\e[34m'; BLD=$'\e[1m'; DIM=$'\e[2m'; OFF=$'\e[0m'; else RED=""; GRN=""; YEL=""; BLU=""; BLD=""; DIM=""; OFF=""; fi
die()  { printf '%ssysops: error:%s %s\n' "$RED" "$OFF" "$*" >&2; exit 2; }
warn() { printf '%ssysops: warning:%s %s\n' "$YEL" "$OFF" "$*" >&2; }
jesc() { local s=$1; s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\n'/\\n}; printf '%s' "$s"; }
# append-only audit journal: who did what, when (JSON lines)
journal() { # action target detail
  mkdir -p "$STATE"; chmod 700 "$STATE" 2>/dev/null || true
  printf '{"time":"%s","user":"%s","action":"%s","target":"%s","detail":"%s"}\n' "$(date -u +%FT%TZ)" "${SUDO_USER:-$(id -un)}" "$1" "$(jesc "$2")" "$(jesc "${3:-}")" >> "$STATE/journal.jsonl"
}
human() { numfmt --to=iec --suffix=B "$1" 2>/dev/null || echo "${1}B"; }
