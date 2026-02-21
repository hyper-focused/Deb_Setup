#!/bin/bash
# =============================================================================
# init.sh — Proxmox VE 9 / Debian 13 post-install setup
# Repo:   https://github.com/hyper-focused/Deb_Setup
# Usage:  bash <(curl -fsSL https://raw.githubusercontent.com/hyper-focused/Deb_Setup/main/init.sh)
# =============================================================================
set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/hyper-focused/Deb_Setup/main"
REPO_CONFIGS="$REPO_RAW/configs"
LOGFILE="/var/log/deb-setup-init.log"
exec > >(tee -a "$LOGFILE") 2>&1
echo "=== INIT START $(date) ==="

trap 'echo ""; echo "ERROR at line $LINENO — see $LOGFILE"; exit 1' ERR

# ── Root check ────────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && { echo "ERROR: Run as root (sudo -i or su -)"; exit 1; }

# ── OS selection ──────────────────────────────────────────────────────────────
echo ""
echo "Select target OS:"
echo "  1) Proxmox VE 9"
echo "  2) Debian 13"
echo ""
read -rp "Choice [1/2]: " _choice
case "$_choice" in
    1|pve|proxmox)  MODE="pve"    ;;
    2|debian|deb)   MODE="debian" ;;
    *) echo "Invalid choice: $_choice"; exit 1 ;;
esac
echo "Mode: $MODE"

# ── Package lists ─────────────────────────────────────────────────────────────

# Installed on both PVE and Debian
COMMON_PKGS=(
    # Shell & terminal
    bash-completion btop htop screen tmux
    zsh zsh-autosuggestions zsh-syntax-highlighting

    # Text / file tools
    bat bc delta fd-find fzf jq lzop pv
    ripgrep shfmt sqlite3 tree ugrep unzip
    vivid w3m wget whois xz-utils yamllint yq zip zstd

    # Network
    bind9-dnsutils curl ethtool ipmitool ipset lsof mtr
    net-tools nmap rsync snmp snmpd snmp-mibs-downloader
    socat tcpdump traceroute

    # Hardware & system
    chrony dmidecode gdisk hdparm lm-sensors lsb-release
    nvme-cli parted pciutils pigz smartmontools
    strace usbutils xfsprogs

    # Dev & scripting
    build-essential git gnupg pipx

    # Misc
    dtach man-db nano starship
)

# PVE-only extras
PVE_EXTRA_PKGS=(
    amd64-microcode
    certbot
    collectd
    collectd-utils
    cpanminus
    cpuinfo
    cstream
    faketime
    fdutils
    frr
    frr-pythontools
    imagemagick
    inetutils-telnet
    ipmiutil
    libguestfs-tools
    minicom
    ntfs-3g
    openipmi
    pflogsumm
    proxmox-firewall
    python3-json5
    rsyslog
    ruby
    snmptrapd
    virt-manager
    virtiofsd
    xterm
    zram-tools
)

# ── Step counter ──────────────────────────────────────────────────────────────
STEP=0
step() {
    STEP=$((STEP + 1))
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Step $STEP: $*"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# =============================================================================
# 1. System update
# =============================================================================
step "System update"
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get -y full-upgrade

# =============================================================================
# 2. Package installation
# =============================================================================
step "Common packages"
DEBIAN_FRONTEND=noninteractive apt-get -y install "${COMMON_PKGS[@]}"

if [[ "$MODE" == "pve" ]]; then
    step "PVE-specific packages"
    for pkg in "${PVE_EXTRA_PKGS[@]}"; do
        DEBIAN_FRONTEND=noninteractive apt-get -y install "$pkg" \
            || echo "  WARNING: $pkg failed or not found — skipping"
    done
fi

# =============================================================================
# 3. bat config
# =============================================================================
step "bat config"
mkdir -p /root/.config/bat
if [[ ! -f /root/.config/bat/config ]]; then
    wget -qO /root/.config/bat/config "$REPO_CONFIGS/bat/config"
    echo "  OK: bat config installed"
else
    echo "  SKIP: bat config already present"
fi

# =============================================================================
# 4. bat-extras  (batgrep, batdiff, batman, batwatch, etc.)
# =============================================================================
step "bat-extras"
if ! command -v batgrep &>/dev/null; then
    _tmp="$(mktemp -d)"
    git clone --depth=1 https://github.com/eth-p/bat-extras.git "$_tmp"
    bash "$_tmp/build.sh" --install --prefix=/usr/local
    rm -rf "$_tmp"
    echo "  OK: bat-extras installed"
else
    echo "  SKIP: bat-extras already installed"
fi

# =============================================================================
# 5. Starship config
# =============================================================================
step "Starship config"
mkdir -p /root/.config
if [[ ! -f /root/.config/starship.toml ]]; then
    wget -qO /root/.config/starship.toml "$REPO_CONFIGS/starship.toml"
    echo "  OK: starship.toml installed"
else
    echo "  SKIP: starship.toml already present"
fi

# =============================================================================
# 6. NVM + Node LTS + Direnv  [PVE only]
# =============================================================================
if [[ "$MODE" == "pve" ]]; then
    step "NVM + Node LTS"
    if [[ ! -d ~/.nvm ]]; then
        git clone https://github.com/nvm-sh/nvm.git ~/.nvm
        export NVM_DIR="$HOME/.nvm"
        # shellcheck source=/dev/null
        . "$NVM_DIR/nvm.sh"
        nvm install --lts || echo "  WARNING: NVM LTS install failed"
        echo "  OK: NVM + Node LTS installed"
    else
        echo "  SKIP: NVM already installed"
    fi

    step "Direnv"
    if ! command -v direnv &>/dev/null; then
        _tmp="$(mktemp -d)"
        git clone https://github.com/direnv/direnv.git "$_tmp"
        (cd "$_tmp" && make install) || echo "  WARNING: Direnv build failed"
        rm -rf "$_tmp"
        echo "  OK: Direnv installed"
    else
        echo "  SKIP: Direnv already installed"
    fi
else
    step "NVM + Direnv — skipped (Debian mode)"
fi

# =============================================================================
# 7. FiraCode Nerd Font
# =============================================================================
step "FiraCode Nerd Font"
FONT_DIR="/usr/local/share/fonts/nerdfonts"
if [[ ! -d "$FONT_DIR" ]] || [[ -z "$(ls -A "$FONT_DIR" 2>/dev/null)" ]]; then
    mkdir -p "$FONT_DIR"
    wget -qO "$FONT_DIR/FiraCode.zip" \
        "https://github.com/ryanoasis/nerd-fonts/releases/download/v3.2.1/FiraCode.zip"
    unzip -qo "$FONT_DIR/FiraCode.zip" -d "$FONT_DIR"
    rm "$FONT_DIR/FiraCode.zip"
    fc-cache -fv
    echo "  OK: FiraCode Nerd Font installed"
else
    echo "  SKIP: FiraCode already installed"
fi

# =============================================================================
# 8. nano syntax highlighting  (scopatz/nanorc)
# =============================================================================
step "nano syntax highlighting"
if [[ ! -d /root/.nano/.git ]]; then
    [[ -d /root/.nano ]] && rm -rf /root/.nano
    git clone https://github.com/scopatz/nanorc.git /root/.nano
    printf "# nano syntax — auto-generated by init.sh\n" > /root/.nanorc
    for f in /root/.nano/*.nanorc; do
        [[ -f "$f" ]] && printf 'include "%s"\n' "$f" >> /root/.nanorc
    done
    echo "  OK: nano syntax installed"
else
    echo "  SKIP: nano syntax already installed"
fi

# =============================================================================
# 9. Configs from hyper-focused/Deb_Setup
# =============================================================================
step "Configs from repo"

# .bashrc
[[ -f /root/.bashrc && ! -f /root/.bashrc.orig ]] \
    && cp /root/.bashrc /root/.bashrc.orig \
    && echo "  Backed up existing .bashrc → .bashrc.orig"
wget -qO /root/.bashrc "$REPO_CONFIGS/bashrc"
echo "  OK: .bashrc installed"

# sshd_config
SSHD="/etc/ssh/sshd_config"
[[ -f "$SSHD" && ! -f "${SSHD}.orig" ]] \
    && cp "$SSHD" "${SSHD}.orig" \
    && echo "  Backed up original sshd_config"
wget -qO "${SSHD}.new" "$REPO_CONFIGS/sshd_config"
if sshd -t -f "${SSHD}.new" 2>/dev/null; then
    mv "${SSHD}.new" "$SSHD"
    systemctl reload sshd
    echo "  OK: sshd_config applied and reloaded"
else
    rm -f "${SSHD}.new"
    echo "  WARNING: sshd_config validation failed — keeping original"
fi

# =============================================================================
# Done
# =============================================================================
echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║   ALL DONE  —  $(date '+%Y-%m-%d %H:%M')                   ║"
echo "╠══════════════════════════════════════════════════╣"
echo "║  Log: $LOGFILE"
echo "╚══════════════════════════════════════════════════╝"
echo ""
echo "Next steps:"
echo "  source ~/.bashrc       # activate aliases & prompt"
echo "  exec zsh               # switch to zsh"
[[ "$MODE" == "pve" ]] && echo "  nvm use --lts          # activate Node LTS"
echo "  tmux new -s main       # start persistent session"
echo "  bat /etc/hosts         # test bat theme"
echo "  nano test.py           # test syntax highlighting"
echo ""
echo "Open a NEW terminal to see Starship + Nerd Fonts."
