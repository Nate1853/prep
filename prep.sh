#!/usr/bin/env bash
#
# prep.sh — prime a fresh Fedora 44+ machine.
# Asks for the sudo password once, then runs unattended.
# Idempotent: safe to rerun. Shows one progress line per item.

set -uo pipefail

# ---- colors ----
if [ -t 1 ]; then
  C_GREEN=$'\033[32m'; C_RED=$'\033[31m'; C_DIM=$'\033[2m'; C_HDR=$'\033[1;36m'; C_RESET=$'\033[0m'
else
  C_GREEN=''; C_RED=''; C_DIM=''; C_HDR=''; C_RESET=''
fi

# A banner printed into the verbose stream so each item's output is identifiable.
banner() { printf '\n%s━━━━━━━━━━ %s ━━━━━━━━━━%s\n' "$C_HDR" "$1" "$C_RESET"; }

# Closing checklist. Skips steps that are already done.
next_steps() {
  printf '\n%sNext steps:%s\n' "$C_HDR" "$C_RESET"
  if [ "${CONDA_DEFAULT_ENV:-}" != "venv" ]; then
    printf '\n%sactivate venv:%s\n' "$C_DIM" "$C_RESET"
    printf '  exec bash\n'
  fi
  if [ ! -d "$HOME/Documents/Applications/refurbishment-ui-bolt" ]; then
    printf '\n%sget the project (run when ready):%s\n' "$C_DIM" "$C_RESET"
    printf '  cd ~/Documents/Applications\n'
    printf '  git clone https://github.com/ubiquiti/refurbishment-ui-bolt.git\n'
    printf '  cd refurbishment-ui-bolt/\n'
  fi
  printf '\n%sverify dependencies:%s\n' "$C_DIM" "$C_RESET"
  printf '  pip install -r requirements.txt\n'
  printf '\n%slaunch app:%s\n' "$C_DIM" "$C_RESET"
  printf '  streamlit run src/main.py\n'
}

# ---- dashboard engine: fixed status box at the bottom, verbose scrolls above ----
DESCS=(); CMDS=(); STATE=(); NOTE=()
add_step() { DESCS+=("$1"); CMDS+=("$2"); STATE+=("pending"); NOTE+=(""); }

repeat() { local n="$1" s="$2" o=""; while [ "$n" -gt 0 ]; do o+="$s"; n=$((n - 1)); done; printf '%s' "$o"; }

DASH_ACTIVE=0
goto_scroll() { printf '\033[%d;1H' "$DASH_SR"; }

# Real terminal size. tput is unreliable under `curl | bash`; ask the tty directly.
get_termsize() {
  local sz; sz="$(stty size </dev/tty 2>/dev/null)"   # "rows cols"
  if [[ "$sz" =~ ^[0-9]+\ [0-9]+$ ]]; then
    DASH_ROWS="${sz% *}"; DASH_COLS="${sz#* }"
  else
    DASH_ROWS="$(tput lines 2>/dev/null)"; [[ "$DASH_ROWS" =~ ^[0-9]+$ ]] || DASH_ROWS="${LINES:-24}"
    DASH_COLS="$(tput cols 2>/dev/null)";  [[ "$DASH_COLS" =~ ^[0-9]+$ ]] || DASH_COLS="${COLUMNS:-80}"
  fi
}

draw_border() { # $1=row  $2=top|bottom
  local row="$1" lc rc
  if [ "$2" = top ]; then lc="╭"; rc="╮"; else lc="╰"; rc="╯"; fi
  printf '\033[%d;1H\033[K%s%s%s' "$row" "$lc" "$(repeat $((DASH_COLS - 2)) '─')" "$rc"
  [ "$2" = top ] && printf '\033[%d;3H┤ %sFedora prep%s ├' "$row" "$C_GREEN" "$C_RESET"
}

draw_item() { # $1=index
  local i="$1" icon row st note desc
  st="${STATE[i]}"; note="${NOTE[i]}"; desc="${DESCS[i]}"
  case "$st" in
    run) icon="⏳";; ok) icon="✅";; already) icon="☑️";; fail) icon="❌";; *) icon="⬜";;
  esac
  row=$(( DASH_BOX_TOP + 1 + i ))
  local dn=$(( DASH_COLS - 2 - 6 - ${#desc} - ${#note} )); [ "$dn" -lt 1 ] && dn=1
  printf '\033[%d;1H\033[K│ %s %s %s ' "$row" "$icon" "$desc" "$(repeat "$dn" '.')"
  [ -n "$note" ] && printf '%s%s%s ' "$C_DIM" "$note" "$C_RESET"
  printf '\033[%d;%dH│' "$row" "$DASH_COLS"
}

draw_all() {
  draw_border "$DASH_BOX_TOP" top
  local i; for i in "${!DESCS[@]}"; do draw_item "$i"; done
  draw_border "$(( DASH_BOX_TOP + ${#DESCS[@]} + 1 ))" bottom
}

dash_init() {
  get_termsize
  local n="${#DESCS[@]}"
  DASH_BOX_TOP=$(( DASH_ROWS - n - 1 ))   # row of the top border
  DASH_SR=$(( DASH_BOX_TOP - 1 ))         # bottom of the scrolling region
  printf '\033[2J\033[H'                  # clean canvas
  tput civis 2>/dev/null || true
  printf '\033[1;%dr' "$DASH_SR"          # confine scrolling to the area above the box
  DASH_ACTIVE=1
  draw_all
  goto_scroll
}

dash_cleanup() {
  [ "${DASH_ACTIVE:-0}" -eq 1 ] || return 0
  printf '\033[r\033[%d;1H' "$DASH_ROWS"  # release scroll region, park cursor at the last line
  tput cnorm 2>/dev/null || true
  DASH_ACTIVE=0
}
trap dash_cleanup EXIT INT TERM

# Run command from CMDS[$1]; stream its output (minus markers) above the box.
_run_capture() { # $1=index  $2=statusfile  -> stdout is the verbose stream
  ( eval "${CMDS[$1]}" ) 2>&1 | while IFS= read -r line; do
    case "$line" in
      '##STATUS##'*) printf '%s' "${line#\#\#STATUS\#\#}" >"$2" ;;
      '##RESTART##') : >"$2.r" ;;
      *)             printf '%s\n' "$line" ;;
    esac
  done
  return "${PIPESTATUS[0]}"
}

_status_of() { # $1=rc  $2=statusfile  -> sets REPLY_STATE / REPLY_NOTE
  local rc="$1" sf="$2" marker=""
  [ -s "$sf" ] && marker="$(cat "$sf")"
  REPLY_NOTE=""
  if [ "$rc" -ne 0 ]; then
    REPLY_STATE="fail"
  else
    case "$marker" in already*) REPLY_STATE="already";; *) REPLY_STATE="ok";; esac
    [ -n "$marker" ] && REPLY_NOTE="($marker)"
  fi
  [ -f "$sf.r" ] && REPLY_NOTE="${REPLY_NOTE:+$REPLY_NOTE }(reboot required)"
}

run_step() { # dashboard mode; $1=index
  local i="$1" sf; sf="$(mktemp)"
  STATE[i]="run"; draw_item "$i"; goto_scroll
  banner "${DESCS[i]}"
  _run_capture "$i" "$sf"   # verbose prints straight into the scroll region
  local rc=$?
  _status_of "$rc" "$sf"
  STATE[i]="$REPLY_STATE"; NOTE[i]="$REPLY_NOTE"
  draw_item "$i"; goto_scroll
  rm -f "$sf" "$sf.r"
  return "$rc"
}

run_step_plain() { # fallback (no TTY / tiny terminal); $1=index
  local i="$1" sf; sf="$(mktemp)"
  banner "${DESCS[i]}"
  _run_capture "$i" "$sf" | sed 's/^/    /'
  local rc=${PIPESTATUS[0]}
  _status_of "$rc" "$sf"
  local icon="✅"; case "$REPLY_STATE" in already) icon="☑️";; fail) icon="❌";; esac
  printf '%s %s%s %s\n' "${DESCS[i]}" "${C_DIM}" "${REPLY_NOTE}${C_RESET}" "$icon"
  rm -f "$sf" "$sf.r"
  return "$rc"
}

# ---- checks ----
check_fedora() {
  . /etc/os-release 2>/dev/null || { echo "Cannot read /etc/os-release"; return 1; }
  [ "${ID:-}" = "fedora" ] || { echo "Not Fedora (ID=${ID:-unknown})"; return 1; }
  [ "${VERSION_ID:-0}" -ge 44 ] 2>/dev/null || { echo "Fedora ${VERSION_ID:-?} is older than 44"; return 1; }
  if ! rpm -q plasma-workspace >/dev/null 2>&1 && ! command -v plasmashell >/dev/null 2>&1; then
    echo "KDE Plasma not detected — this script targets the Fedora KDE spin"; return 1
  fi
  # Wayland session (KRDP requires it). Env first, then logind for the graphical session.
  local wl="${XDG_SESSION_TYPE:-}"
  [ -z "$wl" ] && [ -n "${WAYLAND_DISPLAY:-}" ] && wl="wayland"
  if [ "$wl" != "wayland" ]; then
    local s; s="$(loginctl show-user "$USER" -p Display --value 2>/dev/null)"
    [ -n "$s" ] && wl="$(loginctl show-session "$s" -p Type --value 2>/dev/null)"
  fi
  [ "$wl" = "wayland" ] || { echo "Not a Wayland session (type=${wl:-unknown}) — KRDP requires Wayland"; return 1; }
  echo "Fedora ${VERSION_ID} (KDE Plasma, Wayland) detected"
}

check_amd() {
  grep -q "AuthenticAMD" /proc/cpuinfo || { echo "CPU vendor is not AMD"; return 1; }
  # Physical installed RAM via DMI (counts memory reserved for the iGPU, unlike MemTotal).
  local mb=0 gib
  if command -v dmidecode >/dev/null 2>&1; then
    mb="$(sudo dmidecode -t 17 2>/dev/null | awk '
      /^[[:space:]]*Size:/ && $2 ~ /^[0-9]+$/ { if ($3=="GB") s+=$2*1024; else if ($3=="MB") s+=$2 }
      END { print s+0 }')"
  fi
  if [ "${mb:-0}" -gt 0 ]; then
    gib=$(( (mb + 512) / 1024 ))
    echo "AMD CPU, ${gib} GB RAM installed"
  else
    local memkb; memkb="$(awk '/^MemTotal:/{print $2}' /proc/meminfo)"
    gib=$(( (memkb + 524288) / 1048576 ))
    echo "AMD CPU, ${gib} GiB RAM usable (DMI unavailable)"
  fi
  [ "$gib" -ge 8 ] || { echo "Only ${gib} GB RAM (need 8 GB+)"; return 1; }
}

upgrade_system() {
  local logf rc; logf="$(mktemp)"
  # Discover/PackageKit can hold the package lock on a fresh install; release it.
  sudo systemctl stop packagekit 2>/dev/null || true
  sudo dnf upgrade --refresh -y 2>&1 | tee "$logf"   # stream live AND capture
  rc=${PIPESTATUS[0]}
  if [ "$rc" -ne 0 ]; then rm -f "$logf"; return 1; fi
  if grep -qiE 'nothing to do' "$logf"; then
    echo "##STATUS##already up to date"
  else
    echo "##STATUS##successfully updated"
  fi
  rm -f "$logf"
  # Fedora reboot hint: needs-restarting -r exits 1 when a reboot is advised.
  local r; sudo dnf needs-restarting -r >/dev/null 2>&1; r=$?
  [ "$r" -eq 1 ] && echo "##RESTART##"
  return 0
}

install_pkg() {
  local pkg="$1" logf rc; logf="$(mktemp)"
  sudo dnf install -y "$pkg" 2>&1 | tee "$logf"      # stream live AND capture
  rc=${PIPESTATUS[0]}
  if [ "$rc" -ne 0 ]; then rm -f "$logf"; return 1; fi
  if grep -qiE 'nothing to do|already installed' "$logf"; then
    echo "##STATUS##already installed"
  else
    echo "##STATUS##successfully installed"
  fi
  rm -f "$logf"
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

setup_conda() {
  local changed=0
  local conda="$HOME/miniconda3/bin/conda"
  local me; me="$(whoami)"

  # 1. sudoers drop-ins (Fedora: dnf instead of apt/dpkg/debconf)
  _sudoers() {  # $1=filename  $2=content
    local f="/etc/sudoers.d/$1"
    if [ "$(sudo cat "$f" 2>/dev/null)" != "$2" ]; then
      echo "$2" | sudo tee "$f" >/dev/null || return 1
      changed=1
    fi
    sudo chmod 0440 "$f" || return 1   # sudoers.d files must be 0440
  }
  _sudoers uibolt-nic "$me ALL=(ALL) NOPASSWD: /usr/bin/rm, /usr/sbin/ip, /usr/bin/tee, /usr/bin/udevadm, /usr/bin/systemctl, /usr/bin/networkctl, /usr/sbin/arping" || return 1
  _sudoers uibolt-dnf "$me ALL=(ALL) SETENV: NOPASSWD: /usr/bin/dnf, /usr/bin/rpm" || return 1
  _sudoers uibolt-uos "$me ALL=(ALL) NOPASSWD: /tmp/unifi-os-server-installer, /usr/sbin/usermod" || return 1
  sudo visudo -c >/dev/null || return 1

  # 2. Miniconda (batch, non-interactive; -u tolerates an existing dir)
  if [ ! -x "$conda" ]; then
    curl -fsSL https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh -o /tmp/miniconda.sh || return 1
    bash /tmp/miniconda.sh -b -u -p "$HOME/miniconda3" || return 1
    changed=1
  fi

  # 3. conda init + accept ToS (all idempotent)
  "$conda" init bash || return 1
  "$conda" tos accept --override-channels --channel https://repo.anaconda.com/pkgs/main || return 1
  "$conda" tos accept --override-channels --channel https://repo.anaconda.com/pkgs/r    || return 1

  # 4. Create the 'venv' environment if it doesn't exist
  if ! "$conda" env list | awk '{print $1}' | grep -qx venv; then
    "$conda" create -n venv python=3.12.11 -y || return 1
    changed=1
  fi

  [ "$changed" -eq 1 ] && echo "##STATUS##successfully configured" || echo "##STATUS##already configured"
}

activate_venv() {
  local conda="$HOME/miniconda3/bin/conda" line="conda activate venv"
  # Confirm the env exists, then make every new shell start in it.
  "$conda" env list | awk '{print $1}' | grep -qx venv || { echo "venv environment not found"; return 1; }
  if grep -qxF "$line" "$HOME/.bashrc" 2>/dev/null; then
    echo "##STATUS##already configured"; return 0
  fi
  printf '%s\n' "$line" >> "$HOME/.bashrc" || return 1
  echo "##STATUS##successfully configured"
}

set_default_browser() {
  # xdg-settings/xdg-mime shell out to `qtpaths` (named qtpaths6 on Fedora KDE) and
  # fail, so write what Plasma actually reads directly: kdeglobals + mimeapps.list.
  local desktop="google-chrome.desktop"
  local cur_kde cur_mime
  cur_kde="$(kreadconfig6 --file kdeglobals --group General --key BrowserApplication 2>/dev/null)"
  cur_mime="$(kreadconfig6 --file mimeapps.list --group 'Default Applications' --key 'x-scheme-handler/https' 2>/dev/null)"
  if [ "$cur_kde" = "$desktop" ] && [ "$cur_mime" = "$desktop" ]; then
    echo "##STATUS##already configured"; return 0
  fi

  kwriteconfig6 --file kdeglobals --group General --key BrowserApplication "$desktop" || return 1
  local k
  for k in x-scheme-handler/http x-scheme-handler/https text/html x-scheme-handler/about x-scheme-handler/unknown; do
    kwriteconfig6 --file mimeapps.list --group 'Default Applications' --key "$k" "$desktop" || return 1
  done
  xdg-settings set default-web-browser "$desktop" 2>/dev/null || true   # best effort
  echo "##STATUS##successfully configured"
}

setup_appdir() {
  local d="$HOME/Documents/Applications"
  if [ -d "$d" ]; then
    echo "##STATUS##already exists"; return 0
  fi
  mkdir -p "$d" || return 1
  echo "##STATUS##created"
}

set_no_sleep() {
  # Never auto-suspend/hibernate on idle (monitor/screen blanking left untouched).
  # Three layers: mask sleep targets (authoritative — any suspend is refused),
  # logind IdleAction=ignore, and set KDE PowerDevil "When inactive -> Do nothing".
  local targets="sleep.target suspend.target hibernate.target hybrid-sleep.target"
  local ld=/etc/systemd/logind.conf.d/10-no-idle.conf
  local masked=1 pd_done=0 t

  for t in $targets; do
    [ "$(systemctl is-enabled "$t" 2>/dev/null)" = "masked" ] || masked=0
  done
  # Plasma 6 stores "When inactive" in powerdevilrc; 0 = Do nothing.
  [ "$(kreadconfig6 --file powerdevilrc --group AC --group SuspendAndShutdown --key AutoSuspendAction 2>/dev/null)" = "0" ] && pd_done=1

  if [ "$masked" -eq 1 ] && [ -f "$ld" ] && [ "$pd_done" -eq 1 ]; then
    echo "##STATUS##already configured"; return 0
  fi

  sudo systemctl mask $targets || return 1
  sudo mkdir -p /etc/systemd/logind.conf.d || return 1
  printf '[Login]\nIdleAction=ignore\n' | sudo tee "$ld" >/dev/null || return 1

  # PowerDevil: When inactive -> Do nothing.
  kwriteconfig6 --file powerdevilrc --group AC --group SuspendAndShutdown --key AutoSuspendAction 0 || return 1
  qdbus  org.kde.Solid.PowerManagement /org/kde/Solid/PowerManagement reparseConfiguration 2>/dev/null \
    || qdbus6 org.kde.Solid.PowerManagement /org/kde/Solid/PowerManagement reparseConfiguration 2>/dev/null || true

  echo "##STATUS##successfully configured"
}

enable_vkms() {
  local loaded=0 conf=0
  [ -d /sys/module/vkms ] && loaded=1                                  # loaded or built-in
  grep -qxs vkms /etc/modules-load.d/vkms.conf && conf=1               # set to autoload at boot
  echo "vkms loaded now: $loaded   autoload configured: $conf"
  if [ "$loaded" -eq 1 ] && [ "$conf" -eq 1 ]; then
    echo "##STATUS##already configured"; return 0
  fi

  # Set autoload first so a reboot loads it even if loading now misbehaves.
  [ "$conf" -eq 1 ] || echo "vkms" | sudo tee /etc/modules-load.d/vkms.conf >/dev/null || return 1

  # Load now, with retries — modprobe can transiently segfault on a fresh boot.
  # Trust /sys/module/vkms, not modprobe's exit code.
  if [ "$loaded" -ne 1 ]; then
    local i
    for i in 1 2 3; do
      sudo modprobe vkms 2>&1 || true
      [ -d /sys/module/vkms ] && { loaded=1; break; }
      sleep 1
    done
  fi

  if [ "$loaded" -eq 1 ]; then
    echo "##STATUS##successfully configured"
  else
    echo "could not load vkms now; it will load on next boot via /etc/modules-load.d/vkms.conf"
    echo "##STATUS##configured, loads on reboot"
  fi
}

krdp_portal_grant() {
  # Pre-authorize the RemoteDesktop portal so KWin never shows the consent dialog
  # (xdg-desktop-portal-kde checks table "kde-authorized" / id "remote-desktop").
  # krdp is a host app; grant its app id and the empty (host) id.
  local app
  for app in "org.kde.krdpserver" ""; do
    gdbus call --session \
      --dest org.freedesktop.impl.portal.PermissionStore \
      --object-path /org/freedesktop/impl/portal/PermissionStore \
      --method org.freedesktop.impl.portal.PermissionStore.SetPermission \
      kde-authorized true remote-desktop "$app" "['yes']" >/dev/null 2>&1 || true
  done
}

enable_krdp() {
  # Runs as the CURRENT user (krdp is a per-user service), sudo only for pkg/firewall.
  local krdp_dir="$HOME/.local/share/krdp"
  local crt="$krdp_dir/server.crt" key="$krdp_dir/server.key"

  krdp_portal_grant   # skip the KWin remote-desktop consent popup

  # Already fully set up?
  local fw_ok=1
  if systemctl is-active --quiet firewalld; then
    sudo firewall-cmd --query-port=3389/tcp >/dev/null 2>&1 || fw_ok=0
  fi
  if command -v krdpserver >/dev/null 2>&1 \
     && [ -f "$crt" ] && [ -f "$key" ] \
     && [ "$(kreadconfig6 --file krdpserverrc --group General --key SystemUserEnabled)" = "true" ] \
     && [ "$(kreadconfig6 --file krdpserverrc --group General --key Autostart)" = "true" ] \
     && systemctl --user is-active --quiet app-org.kde.krdpserver.service \
     && [ "$fw_ok" -eq 1 ]; then
    echo "##STATUS##already configured"; return 0
  fi

  command -v krdpserver >/dev/null 2>&1 || sudo dnf install -y krdp-server || return 1
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

# ---- register the items (desc, command) ----
add_step "Fedora 44+ (KDE, Wayland)"     "check_fedora"
add_step "AMD CPU + 8GB+ RAM"            "check_amd"
add_step "Upgrade system packages"       "upgrade_system"
add_step "Enable OpenSSH + open firewall" "enable_ssh"
add_step "Enable KRDP remote desktop"    "enable_krdp"
add_step "Virtual display (vkms)"        "enable_vkms"
add_step "Never sleep when idle"         "set_no_sleep"
add_step "Install fastfetch"             "install_pkg fastfetch"
add_step "Install Google Chrome"         "install_chrome"
add_step "Set Chrome as default browser" "set_default_browser"
add_step "Install sshpass"               "install_pkg sshpass"
add_step "Install expect"                "install_pkg expect"
add_step "Install cups"                  "install_pkg cups"
add_step "Install arping"                "install_pkg arping"
add_step "Install net-tools"             "install_pkg net-tools"
add_step "Install iperf3"                "install_pkg iperf3"
add_step "Conda + venv (python 3.12.11)" "setup_conda"
add_step "Activate venv on login"        "activate_venv"
add_step "Documents/Applications folder" "setup_appdir"

# ---- ask for sudo once, keep it alive until the script exits ----
sudo -v
( while true; do sudo -n true; sleep 60; kill -0 "$$" 2>/dev/null || exit; done ) &

# Use the dashboard only on a real terminal that's tall enough; else plain output.
N="${#DESCS[@]}"; USE_DASH=0
if [ -t 1 ]; then
  get_termsize
  [ "$DASH_ROWS" -ge $(( N + 4 )) ] && USE_DASH=1   # box is N+2 rows; need a couple rows to scroll
fi

if [ "$USE_DASH" -eq 1 ]; then
  dash_init
  for i in "${!DESCS[@]}"; do
    run_step "$i" || { [ "$i" -le 1 ] && break; }   # abort only if Fedora/AMD checks fail
  done
  dash_cleanup
  printf '\n%sDone.%s\n' "$C_GREEN" "$C_RESET"
  next_steps
else
  echo "${C_DIM}Priming this Fedora machine…${C_RESET}"
  for i in "${!DESCS[@]}"; do
    run_step_plain "$i" || { [ "$i" -le 1 ] && break; }
  done
  printf '%sDone.%s\n' "$C_GREEN" "$C_RESET"
  next_steps
fi
