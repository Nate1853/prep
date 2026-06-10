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

  # Annotate the line. An explicit ##STATUS##<text> line from the step wins;
  # otherwise fall back to scanning the output.
  local note=""
  local marker; marker="$(grep -m1 '^##STATUS##' "$log" 2>/dev/null | sed 's/^##STATUS##//')"
  if [ -n "$marker" ]; then
    note=" ($marker)"
  elif [ "$rc" -eq 0 ]; then
    grep -qiE 'already installed|nothing to do'      "$log" && note+=" (already installed)"
    grep -qE  '^Installed:|successfully installed'   "$log" && note+=" (installed)"
  fi
  grep -qiE 'reboot|restart' "$log" && note+=" (requires restart)"

  local cols; cols="$(tput cols 2>/dev/null)"
  [[ "$cols" =~ ^[0-9]+$ ]] || cols="${COLUMNS:-80}"
  [[ "$cols" =~ ^[0-9]+$ ]] || cols=80
  local emoji="✅"; [ "$rc" -eq 0 ] || emoji="❌"
  if [ "$rc" -eq 0 ]; then case "$marker" in already*) emoji="☑️" ;; esac; fi
  local pad=$(( cols - ${#desc} - ${#note} - 4 )); [ "$pad" -lt 1 ] && pad=1
  local dots; dots="$(printf '%*s' "$pad" '' | tr ' ' '.')"
  local note_disp=""; [ -n "$note" ] && note_disp="${C_DIM}${note}${C_RESET}"

  printf '\r\033[K%s %s%s %s\n' "$desc" "$dots" "$note_disp" "$emoji"
  [ "$rc" -eq 0 ] || grep -v '^##STATUS##' "$log" | sed 's/^/    /'
  rm -f "$log"
  return "$rc"
}

# ---- checks ----
check_fedora() {
  . /etc/os-release 2>/dev/null || { echo "Cannot read /etc/os-release"; return 1; }
  [ "${ID:-}" = "fedora" ] || { echo "Not Fedora (ID=${ID:-unknown})"; return 1; }
  [ "${VERSION_ID:-0}" -ge 44 ] 2>/dev/null || { echo "Fedora ${VERSION_ID:-?} is older than 44"; return 1; }
}

check_amd() {
  grep -q "AuthenticAMD" /proc/cpuinfo || { echo "CPU vendor is not AMD"; return 1; }
}

install_pkg() {
  local pkg="$1"
  if rpm -q "$pkg" >/dev/null 2>&1; then
    echo "##STATUS##already installed"; return 0
  fi
  sudo dnf install -y "$pkg" || return 1
  echo "##STATUS##successfully installed"
}

install_chrome() {
  if rpm -q google-chrome-stable >/dev/null 2>&1; then
    echo "##STATUS##already installed"; return 0
  fi
  sudo tee /etc/yum.repos.d/google-chrome.repo >/dev/null <<'EOF'
[google-chrome]
name=google-chrome
baseurl=https://dl.google.com/linux/chrome/rpm/stable/x86_64
enabled=1
gpgcheck=1
gpgkey=https://dl.google.com/linux/linux_signing_key.pub
EOF
  sudo dnf install -y google-chrome-stable || return 1
  echo "##STATUS##successfully installed"
}

enable_vkms() {
  if lsmod | grep -q '^vkms ' && grep -qxs vkms /etc/modules-load.d/vkms.conf; then
    echo "##STATUS##already configured"; return 0
  fi
  sudo modprobe vkms || return 1
  echo "vkms" | sudo tee /etc/modules-load.d/vkms.conf >/dev/null || return 1
  echo "##STATUS##successfully configured"
}

enable_krdp() {
  # Runs as the CURRENT user (krdp is a per-user service), sudo only for pkg/firewall.
  local krdp_dir="$HOME/.local/share/krdp"
  local crt="$krdp_dir/server.crt" key="$krdp_dir/server.key"

  # Already fully set up?
  local fw_ok=1
  if systemctl is-active --quiet firewalld; then
    sudo firewall-cmd --query-port=3389/tcp >/dev/null 2>&1 || fw_ok=0
  fi
  if rpm -q krdp-server >/dev/null 2>&1 \
     && [ -f "$crt" ] && [ -f "$key" ] \
     && [ "$(kreadconfig6 --file krdpserverrc --group General --key SystemUserEnabled)" = "true" ] \
     && [ "$(kreadconfig6 --file krdpserverrc --group General --key Autostart)" = "true" ] \
     && systemctl --user is-active --quiet app-org.kde.krdpserver.service \
     && [ "$fw_ok" -eq 1 ]; then
    echo "##STATUS##already configured"; return 0
  fi

  rpm -q krdp-server >/dev/null 2>&1 || sudo dnf install -y krdp-server || return 1
  mkdir -p "$krdp_dir"
  if [ ! -f "$crt" ] || [ ! -f "$key" ]; then
    openssl req -nodes -new -x509 -keyout "$key" -out "$crt" -days 3650 -batch || return 1
  fi

  kwriteconfig6 --file krdpserverrc --group General --key Certificate "$crt" || return 1
  kwriteconfig6 --file krdpserverrc --group General --key CertificateKey "$key" || return 1
  kwriteconfig6 --file krdpserverrc --group General --key SystemUserEnabled true || return 1
  kwriteconfig6 --file krdpserverrc --group General --key Autostart true || return 1

  systemctl --user enable --now app-org.kde.krdpserver.service || return 1

  if systemctl is-active --quiet firewalld; then
    sudo firewall-cmd --permanent --add-port=3389/tcp || return 1
    sudo firewall-cmd --reload || return 1
  fi
  echo "##STATUS##successfully configured"
}

enable_ssh() {
  # Already fully set up?
  local fw_ok=1
  if systemctl is-active --quiet firewalld; then
    { sudo firewall-cmd --query-service=ssh >/dev/null 2>&1 \
      && sudo firewall-cmd --query-port=21/tcp >/dev/null 2>&1; } || fw_ok=0
  fi
  if rpm -q openssh-server >/dev/null 2>&1 \
     && systemctl is-enabled --quiet sshd \
     && systemctl is-active --quiet sshd \
     && [ "$fw_ok" -eq 1 ]; then
    echo "##STATUS##already configured"; return 0
  fi

  rpm -q openssh-server >/dev/null 2>&1 || sudo dnf install -y openssh-server || return 1
  sudo systemctl enable --now sshd || return 1
  if systemctl is-active --quiet firewalld; then
    sudo firewall-cmd --permanent --add-service=ssh || return 1
    sudo firewall-cmd --permanent --add-port=21/tcp || return 1
    sudo firewall-cmd --reload || return 1
  fi
  echo "##STATUS##successfully configured"
}

# ---- ask for sudo once, keep it alive until the script exits ----
sudo -v
while true; do sudo -n true; sleep 60; kill -0 "$$" 2>/dev/null || exit; done &

echo "${C_DIM}Priming this Fedora machine…${C_RESET}"

run_step "Fedora 44 or later"     check_fedora || exit 1
run_step "AMD CPU"                check_amd    || exit 1
run_step "Upgrade system packages" sudo dnf upgrade --refresh -y
run_step "Enable OpenSSH + open firewall" enable_ssh
run_step "Enable KRDP remote desktop"     enable_krdp
run_step "Virtual display (vkms)"         enable_vkms
run_step "Install fastfetch"              install_pkg fastfetch
run_step "Install Google Chrome"          install_chrome
run_step "Install sshpass"                install_pkg sshpass
run_step "Install expect"                 install_pkg expect
run_step "Install cups"                   install_pkg cups
run_step "Install arping"                 install_pkg arping
run_step "Install net-tools"              install_pkg net-tools
run_step "Install iperf3"                 install_pkg iperf3

echo "${C_GREEN}Done.${C_RESET}"
