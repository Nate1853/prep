#!/usr/bin/env bash
#
# prep.sh — prime a fresh Fedora 44+ machine.
# Asks for the sudo password once, then runs unattended.
# Idempotent: safe to rerun. Shows one progress line per item.

set -uo pipefail

# ---- colors ----
if [ -t 1 ]; then
  C_GREEN=$'\033[32m'; C_RED=$'\033[31m'; C_DIM=$'\033[2m'; C_RESET=$'\033[0m'
else
  C_GREEN=''; C_RED=''; C_DIM=''; C_RESET=''
fi

# ---- per-item step runner: spinner while running, ✓/✗ in place ----
run_step() {
  local desc="$1"; shift
  local log; log="$(mktemp)"

  "$@" >"$log" 2>&1 &
  local pid=$!

  local frames='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏' i=0
  tput civis 2>/dev/null || true
  while kill -0 "$pid" 2>/dev/null; do
    i=$(( (i + 1) % ${#frames} ))
    printf '\r\033[K%s %s' "${frames:$i:1}" "$desc"
    sleep 0.1
  done
  wait "$pid"; local rc=$?
  tput cnorm 2>/dev/null || true

  if [ "$rc" -eq 0 ]; then
    printf '\r\033[K%s✓%s %s\n' "$C_GREEN" "$C_RESET" "$desc"
  else
    printf '\r\033[K%s✗%s %s\n' "$C_RED" "$C_RESET" "$desc"
    sed 's/^/    /' "$log"
  fi
  rm -f "$log"
  return "$rc"
}

# ---- ask for sudo once, keep it alive until the script exits ----
sudo -v
while true; do sudo -n true; sleep 60; kill -0 "$$" 2>/dev/null || exit; done &

echo "${C_DIM}Priming this Fedora machine…${C_RESET}"

run_step "Upgrade system packages" sudo dnf upgrade --refresh -y

echo "${C_GREEN}Done.${C_RESET}"
