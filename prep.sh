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
  local bolt_dir="${BOLT_DIR:-$HOME/Documents/Applications/refurbishment-ui-bolt}"
  local bolt_key="${BOLT_KEY:-$HOME/.ssh/id_ed25519_bolt}"

  # No repo yet but a key exists => the deploy key isn't registered with GitHub.
  # Show it (+ what to do) BEFORE the normal next steps. The repo pulls itself on
  # the next run, once the key is in place — no manual clone needed.
  if [ ! -d "$bolt_dir/.git" ] && [ -f "$bolt_key.pub" ]; then
    printf '\n%s━━ Register this machine with GitHub ━━%s\n' "$C_HDR" "$C_RESET"
    printf '%sThe project pulls itself once this deploy key is registered:%s\n\n' "$C_DIM" "$C_RESET"
    printf '  %s1%s  open    https://github.com/ubiquiti/refurbishment-ui-bolt/settings/keys\n' "$C_HDR" "$C_RESET"
    printf '  %s2%s  click   "Add deploy key"\n' "$C_HDR" "$C_RESET"
    printf '  %s3%s  title   %s\n' "$C_HDR" "$C_RESET" "$(hostname -s)"
    printf '  %s4%s  tick    ✅ "Allow write access"  %s— only if truly needed%s\n' "$C_HDR" "$C_RESET" "$C_DIM" "$C_RESET"
    printf '  %s5%s  paste   the key below\n\n' "$C_HDR" "$C_RESET"
    printf '%s%s%s\n\n' "$C_GREEN" "$(cat "$bolt_key.pub")" "$C_RESET"
    printf '%sThen rerun this script.%s\n' "$C_DIM" "$C_RESET"
  fi

  # When we can, the script ends by dropping the user straight into the repo in a
  # fresh shell (see end of file). In that case the venv/cd hints are redundant.
  local drop=0
  [ -d "$bolt_dir/.git" ] && [ -e /dev/tty ] && drop=1

  printf '\n%sNext steps:%s\n' "$C_HDR" "$C_RESET"
  if [ "$drop" -eq 1 ]; then
    printf '\n%sinstalling dependencies & dropping you into the project (venv active) — type %sexit%s to come back here.%s\n' \
      "$C_DIM" "$C_RESET" "$C_DIM" "$C_RESET"
  else
    if [ "${CONDA_DEFAULT_ENV:-}" != "venv" ]; then
      printf '\n%sactivate venv:%s\n' "$C_DIM" "$C_RESET"
      printf '  exec bash\n'
    fi
    if [ -d "$bolt_dir/.git" ]; then
      printf '\n%senter the project:%s\n' "$C_DIM" "$C_RESET"
      printf '  cd %s\n' "$bolt_dir"
    fi
  fi
  # Only suggest installing deps when the repo isn't pulled yet (key unregistered);
  # once it's pulled we cd in and run it automatically (see end of script).
  if [ ! -d "$bolt_dir/.git" ]; then
    printf '\n%sverify dependencies:%s\n' "$C_DIM" "$C_RESET"
    printf '  ./install_requirements.sh\n'
  fi
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
  [ "$2" = top ] && printf '\033[%d;3H┤ %sFedora prep — %s%s ├' "$row" "$C_GREEN" "${PROFILE_SEL:-full}" "$C_RESET"
}

draw_item() { # $1=index
  local i="$1" icon row st note desc
  st="${STATE[i]}"; note="${NOTE[i]}"; desc="${DESCS[i]}"
  case "$st" in
    run) icon="⏳";; ok) icon="✅";; already) icon="☑️";; warn) icon="‼️";; fail) icon="❌";; *) icon="⬜";;
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
      '##WARN##')    : >"$2.w" ;;
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
    [ -f "$sf.w" ] && REPLY_STATE="warn"
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
  rm -f "$sf" "$sf.r" "$sf.w"
  return "$rc"
}

run_step_plain() { # fallback (no TTY / tiny terminal); $1=index
  local i="$1" sf; sf="$(mktemp)"
  banner "${DESCS[i]}"
  _run_capture "$i" "$sf" | sed 's/^/    /'
  local rc=${PIPESTATUS[0]}
  _status_of "$rc" "$sf"
  local icon="✅"; case "$REPLY_STATE" in already) icon="☑️";; warn) icon="‼️";; fail) icon="❌";; esac
  printf '%s %s%s %s\n' "${DESCS[i]}" "${C_DIM}" "${REPLY_NOTE}${C_RESET}" "$icon"
  rm -f "$sf" "$sf.r" "$sf.w"
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
  # AMD is the expected vendor (✅). Intel is allowed but flagged non-blocking (‼️).
  local vendor
  if grep -q "AuthenticAMD" /proc/cpuinfo; then
    vendor="AMD"
  elif grep -q "GenuineIntel" /proc/cpuinfo; then
    vendor="Intel"; echo "##WARN##"; echo "CPU vendor is Intel (not AMD) — continuing anyway"
  else
    echo "CPU vendor is neither AMD nor Intel"; return 1
  fi
  # Physical installed RAM via DMI (counts memory reserved for the iGPU, unlike MemTotal).
  local mb=0 gib
  if command -v dmidecode >/dev/null 2>&1; then
    mb="$(sudo dmidecode -t 17 2>/dev/null | awk '
      /^[[:space:]]*Size:/ && $2 ~ /^[0-9]+$/ { if ($3=="GB") s+=$2*1024; else if ($3=="MB") s+=$2 }
      END { print s+0 }')"
  fi
  if [ "${mb:-0}" -gt 0 ]; then
    gib=$(( (mb + 512) / 1024 ))
    echo "${vendor} CPU, ${gib} GB RAM installed"
  else
    local memkb; memkb="$(awk '/^MemTotal:/{print $2}' /proc/meminfo)"
    gib=$(( (memkb + 524288) / 1048576 ))
    echo "${vendor} CPU, ${gib} GiB RAM usable (DMI unavailable)"
  fi
  [ "$gib" -ge 8 ] || { echo "Only ${gib} GB RAM (need 8 GB+)"; return 1; }
  # CPU model for the status line; trim marketing noise to keep it short.
  local cpu; cpu="$(awk -F': ' '/^model name/{print $2; exit}' /proc/cpuinfo)"
  cpu="$(printf '%s' "$cpu" | sed -E 's/\((R|TM)\)//g; s/ (CPU|Processor)//g; s/ with .*//; s/  +/ /g; s/^ +| +$//g')"
  echo "##STATUS##detected: ${cpu:-$vendor}, ${gib}GB"
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

install_tailscale() {
  # Official installer (adds the repo + installs tailscale/tailscaled). It uses
  # sudo internally — already cached for this run. Doesn't run `tailscale up`
  # (that needs interactive auth); just installs.
  if command -v tailscale >/dev/null 2>&1; then
    echo "##STATUS##already installed"; return 0
  fi
  curl -fsSL https://tailscale.com/install.sh | sh 2>&1 || return 1
  echo "##STATUS##successfully installed"
}

install_zed() {
  # Official per-user installer -> ~/.local/zed.app + a ~/.local/bin/zed symlink.
  # No sudo; runs as the current user.
  if [ -x "$HOME/.local/bin/zed" ] || command -v zed >/dev/null 2>&1; then
    echo "##STATUS##already installed"; return 0
  fi
  curl -fsSL https://zed.dev/install.sh | sh 2>&1 || return 1
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

# Repo coordinates — reused by setup_bolt_repo and next_steps.
BOLT_DIR="$HOME/Documents/Applications/refurbishment-ui-bolt"
BOLT_REPO="git@github.com:ubiquiti/refurbishment-ui-bolt.git"
BOLT_KEY="$HOME/.ssh/id_ed25519_bolt"

setup_bolt_repo() {
  # Per-machine SSH deploy key for the bolt repo (replaces HTTPS+PAT). Idempotent.
  # If the key isn't registered with GitHub yet, the repo can't clone — we leave
  # the public key for next_steps to print. Once it's registered, a rerun pulls.
  mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"

  # 1. ssh-agent user socket so AddKeysToAgent works in GUI + plain ssh shells.
  systemctl --user enable --now ssh-agent.socket >/dev/null 2>&1 || true
  if ! grep -q "ssh-agent.socket" "$HOME/.bashrc" 2>/dev/null; then
    printf '\n# ssh-agent (systemd user socket) for SSH/non-plasma shells\nexport SSH_AUTH_SOCK="${SSH_AUTH_SOCK:-$XDG_RUNTIME_DIR/ssh-agent.socket}"\n' >> "$HOME/.bashrc"
  fi
  export SSH_AUTH_SOCK="${SSH_AUTH_SOCK:-$XDG_RUNTIME_DIR/ssh-agent.socket}"

  # 2. Deploy key (passphraseless, dedicated to this one repo — limited blast radius).
  if [ ! -f "$BOLT_KEY" ]; then
    ssh-keygen -t ed25519 -C "$(hostname -s) refurbishment-ui-bolt deploy" -f "$BOLT_KEY" -N "" >/dev/null || return 1
  fi

  # 3. Route github.com through the key (idempotent — only append our block once).
  touch "$HOME/.ssh/config" && chmod 600 "$HOME/.ssh/config"
  if ! grep -qE "^[[:space:]]*Host[[:space:]]+github\.com" "$HOME/.ssh/config" 2>/dev/null; then
    cat >> "$HOME/.ssh/config" <<EOF

Host github.com
    HostName github.com
    User git
    IdentityFile $BOLT_KEY
    IdentitiesOnly yes
    AddKeysToAgent yes
EOF
  fi

  # 4. git identity, only if unset (GIT_EMAIL/GIT_NAME collected before the dashboard).
  if [ -z "$(git config --global user.email 2>/dev/null)" ] && [ -n "${GIT_EMAIL:-}" ]; then
    git config --global user.email "$GIT_EMAIL"
    git config --global user.name  "${GIT_NAME:-$GIT_EMAIL}"
  fi

  # 5. Try to reach the repo. BatchMode/accept-new => never prompt, never hang.
  export GIT_SSH_COMMAND="ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new"
  if git ls-remote "$BOLT_REPO" >/dev/null 2>&1; then
    if [ -d "$BOLT_DIR/.git" ]; then
      if git -C "$BOLT_DIR" pull --ff-only 2>&1; then
        echo "##STATUS##repo up to date"
      else
        echo "##WARN##"; echo "##STATUS##pull skipped (local changes)"
      fi
    else
      git clone "$BOLT_REPO" "$BOLT_DIR" 2>&1 || return 1
      echo "##STATUS##repo cloned"
    fi
  else
    # Key not registered (or offline) — next_steps prints the key + instructions.
    echo "deploy key not yet registered with GitHub — see closing instructions"
    echo "##WARN##"; echo "##STATUS##register deploy key"
  fi
}

# Ask once (before the dashboard) for the UI username; append @ui.com and derive a
# display name. Keeps the email out of this public script. Only when the bolt step
# is in the profile and git identity isn't already set.
choose_git_email() {
  case " ${PROFILE_KEYS[*]} " in *" boltrepo "*) ;; *) return 0 ;; esac
  [ -n "$(git config --global user.email 2>/dev/null)" ] && return 0
  [ -e /dev/tty ] || return 0
  local lp=""
  while [ -z "$lp" ]; do
    printf '\nGit email — enter your UI username, e.g. john.doe (we append @ui.com): ' >/dev/tty
    read -r lp </dev/tty || return 0
    lp="${lp%@ui.com}"; lp="${lp// /}"
  done
  export GIT_EMAIL="${lp}@ui.com"
  export GIT_NAME="$(printf '%s' "$lp" | tr '._-' '   ' | awk '{for(i=1;i<=NF;i++)$i=toupper(substr($i,1,1)) substr($i,2)}1')"
  printf '  → %s  (%s)\n' "$GIT_EMAIL" "$GIT_NAME" >/dev/tty
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

enable_autologin() {
  # Boot straight into the KDE (Wayland) session with no login password prompt
  # AND no KWallet unlock dialog, so a headless (re)boot lands in Plasma and
  # KRDP autostarts — instead of stalling at a prompt where the per-user krdp
  # service never runs.
  #
  # Fedora 44+ KDE ships Plasma Login Manager (plasmalogin), an SDDM fork that
  # uses the SAME [Autologin] format but reads /etc/plasmalogin.conf.d/ — NOT
  # /etc/sddm.conf.d/. Detect whichever display manager is active and target
  # its drop-in dir, so the same block works on either.
  local me; me="$(whoami)"

  # 1. Wayland Plasma session (KRDP requires Wayland). Prefer plasma.desktop;
  #    fall back to whatever plasma*.desktop is installed.
  local sess=plasma.desktop
  if [ ! -f "/usr/share/wayland-sessions/$sess" ]; then
    local f; f="$(ls /usr/share/wayland-sessions/plasma*.desktop 2>/dev/null | head -n1)"
    [ -n "$f" ] && sess="$(basename "$f")"
  fi
  local want; want="$(printf '[Autologin]\nUser=%s\nSession=%s\n' "$me" "$sess")"

  # 2. Pick the config dir for the active display manager (SDDM-compatible keys).
  local dm dir
  dm="$(systemctl show -p Id --value display-manager.service 2>/dev/null)"
  case "$dm" in
    plasmalogin.service) dir=/etc/plasmalogin.conf.d ;;
    sddm.service)        dir=/etc/sddm.conf.d ;;
    *) if [ -d /etc/plasmalogin.conf.d ]; then dir=/etc/plasmalogin.conf.d; else dir=/etc/sddm.conf.d; fi ;;
  esac
  local conf="$dir/10-autologin.conf"
  echo "Display manager: ${dm:-unknown} -> $conf"

  # 3. KWallet: disable it outright. Under autologin no login password is typed,
  #    so kwallet-pam can never auto-unlock — leaving it enabled means an unlock
  #    dialog blocks the headless session. Disabling kills the prompt for good.
  local kw_done=0
  [ "$(kreadconfig6 --file kwalletrc --group Wallet --key Enabled 2>/dev/null)" = "false" ] && kw_done=1

  # Drop any stale SDDM drop-in we may have written on a prior run with the
  # wrong DM, unless SDDM is the one actually in use.
  if [ "$dir" != /etc/sddm.conf.d ] && [ -f /etc/sddm.conf.d/10-autologin.conf ]; then
    sudo rm -f /etc/sddm.conf.d/10-autologin.conf || true
  fi

  if [ "$(sudo cat "$conf" 2>/dev/null)" = "$want" ] && [ "$kw_done" -eq 1 ]; then
    echo "##STATUS##already configured"; return 0
  fi

  sudo mkdir -p "$dir" || return 1
  printf '%s\n' "$want" | sudo tee "$conf" >/dev/null || return 1
  kwriteconfig6 --file kwalletrc --group Wallet --key Enabled false || return 1

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

# ---- item catalog: key -> (description, command). Declare each item once. ----
declare -A ITEM_DESC ITEM_CMD
item() { ITEM_DESC[$1]="$2"; ITEM_CMD[$1]="$3"; }

item fedora    "Fedora 44+ (KDE, Wayland)"      "check_fedora"
item amd       "AMD CPU + 8GB+ RAM"             "check_amd"
item upgrade   "Upgrade system packages"        "upgrade_system"
item ssh       "Enable OpenSSH + open firewall" "enable_ssh"
item krdp      "Enable KRDP remote desktop"     "enable_krdp"
item autologin "Autologin into KDE on boot (+Kwallet fix)" "enable_autologin"
item vkms      "Virtual display (vkms)"         "enable_vkms"
item nosleep   "Never sleep when idle"          "set_no_sleep"
item fastfetch "Install fastfetch"              "install_pkg fastfetch"
item chrome    "Install Google Chrome"          "install_chrome"
item tailscale "Install Tailscale"              "install_tailscale"
item zed       "Install Zed editor"             "install_zed"
item browser   "Set Chrome as default browser"  "set_default_browser"
item sshpass   "Install sshpass"                "install_pkg sshpass"
item expect    "Install expect"                 "install_pkg expect"
item cups      "Install cups"                   "install_pkg cups"
item arping    "Install arping"                 "install_pkg arping"
item nettools  "Install net-tools"              "install_pkg net-tools"
item iperf3    "Install iperf3"                 "install_pkg iperf3"
item conda     "Conda + venv (python 3.12.11)"  "setup_conda"
item venvlogin "Activate venv on login"         "activate_venv"
item appdir    "Documents/Applications folder"  "setup_appdir"
item boltrepo  "Deploy key + clone/pull bolt repo" "setup_bolt_repo"

# ---- profiles: ordered lists of item keys. EDIT THESE to taste. ----
# keep fedora+amd first (they gate the run). "nextsteps" is a post-run flag
# (prints the closing checklist), not a dashboard step.
PROFILE_full=(fedora amd upgrade ssh krdp autologin vkms nosleep tailscale zed fastfetch chrome browser \
              sshpass expect cups arping nettools iperf3 conda venvlogin appdir boltrepo nextsteps)
PROFILE_bolt=("${PROFILE_full[@]}")                       # bolt == full for now
PROFILE_minimal=(fedora amd upgrade ssh krdp autologin vkms nosleep)  # core only, no installs / no next-steps

# ---- pick the profile (env PROFILE=… overrides; else prompt; else full) ----
choose_profile() {
  local p="${PROFILE:-}"
  if [ -z "$p" ] && [ -e /dev/tty ]; then
    {
      printf '\nSelect install profile:\n'
      printf '  1) full     — everything\n'
      printf '  2) bolt     — same as full (for now)\n'
      printf '  3) minimal  — core setup only, no package installs\n'
      printf 'Choice [1]: '
    } >/dev/tty
    local ans=""; read -r ans </dev/tty || true
    case "$ans" in 2|bolt) p=bolt ;; 3|minimal) p=minimal ;; *) p=full ;; esac
  fi
  case "$p" in bolt|minimal|full) ;; *) p=full ;; esac
  printf '%s' "$p"
}
PROFILE_SEL="$(choose_profile)"

eval 'PROFILE_KEYS=("${PROFILE_'"$PROFILE_SEL"'[@]}")'
for k in "${PROFILE_KEYS[@]}"; do
  [ "$k" = nextsteps ] && continue          # post-run flag, not a step
  add_step "${ITEM_DESC[$k]}" "${ITEM_CMD[$k]}"
done
SHOW_NEXTSTEPS=0; case " ${PROFILE_KEYS[*]} " in *" nextsteps "*) SHOW_NEXTSTEPS=1 ;; esac

# Collect the git email up front (prompt), before the dashboard takes the screen.
choose_git_email

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
  if [ "$SHOW_NEXTSTEPS" -eq 1 ]; then next_steps; fi
else
  echo "${C_DIM}Priming this Fedora machine…${C_RESET}"
  for i in "${!DESCS[@]}"; do
    run_step_plain "$i" || { [ "$i" -le 1 ] && break; }
  done
  printf '%sDone.%s\n' "$C_GREEN" "$C_RESET"
  if [ "$SHOW_NEXTSTEPS" -eq 1 ]; then next_steps; fi
fi

# Land the user inside the project, dependencies installed. A child process can't
# cd the parent shell, so we cd here, activate the venv, run the (quiet) installer,
# then replace this process with a fresh interactive shell already in the repo
# (re-sources ~/.bashrc → venv active). Only when the repo exists and we have a
# real terminal; `exit` returns to the original shell.
BOLT_DIR="${BOLT_DIR:-$HOME/Documents/Applications/refurbishment-ui-bolt}"
if [ "$SHOW_NEXTSTEPS" -eq 1 ] && [ -d "$BOLT_DIR/.git" ] && [ -e /dev/tty ]; then
  cd "$BOLT_DIR" 2>/dev/null || true
  # Activate the venv so deps land in the right env (exports PATH for the installer).
  if [ -f "$HOME/miniconda3/etc/profile.d/conda.sh" ]; then
    . "$HOME/miniconda3/etc/profile.d/conda.sh" && conda activate venv 2>/dev/null || true
  fi
  if [ -f ./install_requirements.sh ]; then
    bash ./install_requirements.sh || printf '%s‼️  install_requirements.sh failed — install deps manually.%s\n' "$C_RED" "$C_RESET"
  else
    printf '%s‼️  install_requirements.sh not found in %s — skipping; install deps manually.%s\n' "$C_RED" "$BOLT_DIR" "$C_RESET"
  fi
  exec bash </dev/tty
fi
