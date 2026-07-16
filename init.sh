#!/bin/bash
# =============================================================================
# init.sh — Proxmox VE 9 / Debian 13 post-install setup
# Repo:   https://github.com/hyper-focused/Deb_Setup
# Usage:  bash <(curl -fsSL https://raw.githubusercontent.com/hyper-focused/Deb_Setup/main/init.sh)
# =============================================================================
set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/hyper-focused/Deb_Setup/main"
REPO_COMMON="$REPO_RAW/configs/common"
# REPO_MODE is set after OS selection: configs/pve or configs/debian
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
REPO_MODE="$REPO_RAW/configs/$MODE"

# ── Failure & attention tracking ──────────────────────────────────────────────
FAILURES=()
NEEDS_ATTENTION=()
warn() { echo "  WARNING: $*"; FAILURES+=("$*"); }

# ── Pre-install state — captured before any packages are installed ─────────────
# Used by confirm_overwrite: don't prompt when the package was just freshly
# installed by this script (its config is still at the distro default).
_pkg_installed() { dpkg -l "$1" 2>/dev/null | grep -q "^ii"; }
_pre_sshd=false;      _pkg_installed openssh-server && _pre_sshd=true
_pre_rsyslog=false;   _pkg_installed rsyslog        && _pre_rsyslog=true
_pre_snmpd=false;     _pkg_installed snmpd          && _pre_snmpd=true
_pre_collectd=false;  _pkg_installed collectd       && _pre_collectd=true
_pre_zram=false;      _pkg_installed zram-tools     && _pre_zram=true

# Prompt before overwriting an existing config file.
# $1 = destination path  $2 = label for prompt  $3 = was-pre-installed (true/false)
# Returns 0 (proceed) when: file absent, or package was just installed (fresh),
#   or user answers y.  Returns 1 (skip) when user declines.
confirm_overwrite() {
    local dst="$1" label="${2:-$1}" pre="${3:-true}"
    [[ ! -f "$dst" ]] && return 0
    [[ "$pre" == "false" ]] && return 0
    local _ans
    read -rp "  $label already exists — overwrite? [y/N]: " _ans
    case "$_ans" in
        y|Y|yes|YES) return 0 ;;
        *) echo "  SKIP: keeping existing $label"; return 1 ;;
    esac
}

# Yes/no prompt. $1 = question  $2 = default (y|n, default y).
# Returns 0 for yes, 1 for no. Enter alone accepts the default.
ask_yn() {
    local prompt="$1" def="${2:-y}" _ans _hint
    if [[ "$def" == "y" ]]; then
        _hint="Y/n"
    else
        _hint="y/N"
    fi
    read -rp "  $prompt [$_hint]: " _ans
    _ans="${_ans:-$def}"
    case "$_ans" in
        y|Y|yes|YES) return 0 ;;
        *) return 1 ;;
    esac
}

# Value prompt with default. $1 = question  $2 = default (may be empty).
# Prints the chosen value to stdout (capture with $()).
ask_val() {
    local prompt="$1" def="${2-}" _ans
    if [[ -n "$def" ]]; then
        read -rp "  $prompt [$def]: " _ans
        printf '%s' "${_ans:-$def}"
    else
        read -rp "  $prompt: " _ans
        printf '%s' "$_ans"
    fi
}

# Install packages without aborting the script.
# Already-installed packages succeed. Unknown/missing packages are warned and skipped.
# Usage: install_pkgs pkg1 pkg2 ...
install_pkgs() {
    local -a _pkgs=("$@")
    local _pkg _ok=0 _fail=0
    [[ ${#_pkgs[@]} -eq 0 ]] && return 0

    # Batch path: fast when every name resolves; one missing name fails the batch.
    if DEBIAN_FRONTEND=noninteractive apt-get -y -q \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold" \
        install "${_pkgs[@]}" 2>/dev/null; then
        echo "  OK: ${#_pkgs[@]} packages installed or already present"
        return 0
    fi

    echo "  Batch incomplete — installing individually (missing packages skipped)..."
    for _pkg in "${_pkgs[@]}"; do
        if _pkg_installed "$_pkg"; then
            _ok=$((_ok + 1))
            continue
        fi
        if DEBIAN_FRONTEND=noninteractive apt-get -y -qq \
            -o Dpkg::Options::="--force-confdef" \
            -o Dpkg::Options::="--force-confold" \
            install "$_pkg" 2>/dev/null; then
            _ok=$((_ok + 1))
        else
            warn "Package unavailable or failed: $_pkg"
            _fail=$((_fail + 1))
        fi
    done
    echo "  Result: $_ok ok/present, $_fail failed/missing"
    return 0
}

# ── Package lists ─────────────────────────────────────────────────────────────

# Installed on both PVE and Debian
# Note: packages pre-installed by PVE (pve-manager/qemu-server deps, Debian standard task)
# are omitted here and listed in DEBIAN_EXTRA_PKGS instead.
COMMON_PKGS=(
    # Shell & terminal
    bash-completion btop htop screen tmux

    # Text / file tools
    bat bc git-delta fd-find fzf jq pv
    ripgrep sqlite3 tree ugrep unzip
    vivid w3m whois xz-utils yq zip

    # Network
    curl ethtool lsof mtr
    net-tools nethogs nload snmp snmpd
    tcpdump
    bind9-dnsutils   # dig, nslookup, host (dnsutils)

    # System
    acl ca-certificates
    duf iperf3 lsb-release
    mosh parted pigz plocate strace sysstat

    # Dev & scripting
    git pipx
    python-is-python3   # bare 'python' not present by default on Debian 13 / PVE 9
    python3-json5       # JSON5 parsing for Python scripts

    # Perl modules for librenms-agent SNMP extend + check_mk scripts
    # Non-core modules that have Debian packages; Statistics::Lite falls back to cpanm below
    cpanminus
    libconfig-tiny-perl
    libdbi-perl
    libfile-find-rule-perl
    libfile-readbackwards-perl
    libfile-slurp-perl
    libio-compress-perl
    libjson-perl
    libstatistics-lite-perl
    libstring-shellquote-perl
    libwww-perl

    # Monitoring (both modes send to collectd server, get polled via SNMP)
    collectd
    collectd-utils

    # Logging
    rsyslog

    # Misc
    nano ncdu starship tig zoxide
)

# PVE-only extras  (bare metal hypervisor)
PVE_EXTRA_PKGS=(
    # Build / scan tools (host-only weight)
    build-essential
    nmap

    # Hardware inventory & firmware
    amd64-microcode
    intel-microcode
    dmidecode
    pciutils
    usbutils
    fio
    ipmitool
    ipmiutil
    lm-sensors
    lsscsi
    minicom          # serial console
    nvme-cli
    nvtop
    smartmontools
    sg3-utils
    stress-ng
    rasdaemon        # hardware error logging (EDAC/MCE)
    edac-utils
    hwinfo
    powertop
    linux-cpupower

    # Storage & filesystem
    zfsutils-linux
    zfs-zed          # ZFS event daemon (scrub/fault alerts)
    libguestfs-tools

    # Network & routing
    # (certbot omitted: PVE manages ACME/TLS certs via its own web UI)
    bridge-utils
    lldpd
    conntrack

    # Monitoring (PVE-extra: richer plugins)
    pflogsumm

    # PVE host extras
    # (proxmox-firewall omitted: tech-preview Recommends only; pve-firewall is pre-installed)
    xterm            # serial / console helpers
    zram-tools
)

# Debian-only extras  (QEMU VM)
# Includes packages that are pre-installed by PVE but absent on a minimal Debian install
DEBIAN_EXTRA_PKGS=(
    qemu-guest-agent   # essential: proper shutdown, snapshots, IP reporting
    cloud-guest-utils  # growpart when QEMU disk is expanded
    needrestart        # post-upgrade restart hints
    file               # file(1) often missing on minimal images

    # Pre-installed on PVE (pve-manager / qemu-server / Debian standard task deps)
    chrony          # NTP daemon
    gdisk           # GPT disk partitioning
    gnupg           # GPG / apt key management
    lzop            # lzop compression
    man-db          # man page viewer
    psmisc          # killall, fuser, pstree
    rsync           # file sync
    socat           # socket relay
    traceroute      # network path tracing
    wget            # HTTP downloads (used throughout this script)
    zstd            # fast compression
)

# ── Step counter ──────────────────────────────────────────────────────────────
STEP=0
step() {
    STEP=$((STEP + 1))
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Step $STEP: $*  [$(date '+%H:%M:%S')]"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# =============================================================================
# 1. System update
# =============================================================================
step "System update"
# ── Enable non-free + non-free-firmware ───────────────────────────────────────
# Required for: snmp-mibs-downloader, intel-microcode, amd64-microcode, firmware-*
if [[ -f /etc/apt/sources.list.d/debian.sources ]]; then
    if ! grep -q 'non-free' /etc/apt/sources.list.d/debian.sources 2>/dev/null; then
        sed -i 's/^Components: main$/Components: main contrib non-free non-free-firmware/' \
            /etc/apt/sources.list.d/debian.sources
        echo "  Enabled: contrib non-free non-free-firmware (debian.sources)"
    else
        echo "  SKIP: non-free already enabled"
    fi
elif [[ -f /etc/apt/sources.list ]]; then
    if ! grep -qE '\bnon-free\b' /etc/apt/sources.list 2>/dev/null; then
        sed -i '/^deb / s/ main$/ main contrib non-free non-free-firmware/' \
            /etc/apt/sources.list
        echo "  Enabled: contrib non-free non-free-firmware (sources.list)"
    else
        echo "  SKIP: non-free already enabled"
    fi
fi
if ! apt-get -q update; then
    warn "apt-get update failed — package installs may be incomplete"
fi
if ! DEBIAN_FRONTEND=noninteractive apt-get -y -q full-upgrade; then
    warn "full-upgrade reported errors — continuing"
fi

# =============================================================================
# 2. Package installation
# =============================================================================
step "Common packages (${#COMMON_PKGS[@]})"
echo "  Installing ${#COMMON_PKGS[@]} packages..."
install_pkgs "${COMMON_PKGS[@]}"

if [[ "$MODE" == "pve" ]]; then
    step "PVE-specific packages (${#PVE_EXTRA_PKGS[@]}, bare metal)"
    install_pkgs "${PVE_EXTRA_PKGS[@]}"
    # Initialise hardware sensor detection (non-interactive, updates /etc/modules)
    if command -v sensors-detect &>/dev/null; then
        sensors-detect --auto > /dev/null 2>&1 \
            || warn "sensors-detect failed — run manually when convenient"
    fi
else
    step "Debian-specific packages (QEMU VM)"
    _qga_was_active=false
    systemctl is-active --quiet qemu-guest-agent 2>/dev/null && _qga_was_active=true
    install_pkgs "${DEBIAN_EXTRA_PKGS[@]}"
    if [[ "$_qga_was_active" == "false" ]] && _pkg_installed qemu-guest-agent; then
        systemctl enable --now qemu-guest-agent 2>/dev/null \
            || warn "qemu-guest-agent enable failed — may already be handled by VM template"
    fi
fi

# CPAN fallback if libstatistics-lite-perl did not land (or module path missing)
if perl -e 'use Statistics::Lite' 2>/dev/null; then
    echo "  SKIP: Statistics::Lite already available"
elif command -v cpanm &>/dev/null; then
    echo "  Installing Statistics::Lite via cpanm..."
    if PERL_MM_USE_DEFAULT=1 cpanm --notest --quiet Statistics::Lite 2>/dev/null; then
        echo "  OK: Statistics::Lite installed via cpanm"
    else
        warn "CPAN: Statistics::Lite install failed — run manually: cpanm Statistics::Lite"
    fi
else
    warn "Statistics::Lite unavailable — cpanm not found; check cpanminus install"
fi

# =============================================================================
# 3. bat config
# =============================================================================
step "bat config"
mkdir -p /root/.config/bat
[[ ! -f /root/.config/bat/config ]] \
    && wget -qO /root/.config/bat/config "$REPO_COMMON/bat/config"

# =============================================================================
# 4. bat-extras  (batgrep, batdiff, batman, batwatch, etc.)
# =============================================================================
step "bat-extras"
if ! command -v batgrep &>/dev/null; then
    _tmp="$(mktemp -d)"
    if git clone -q --depth=1 https://github.com/eth-p/bat-extras.git "$_tmp" 2>/dev/null \
        && bash "$_tmp/build.sh" --install --prefix=/usr/local > /dev/null 2>&1; then
        echo "  OK: bat-extras installed"
    else
        warn "bat-extras install failed — skipping"
    fi
    rm -rf "$_tmp"
fi

# =============================================================================
# 5. Starship config
# =============================================================================
step "Starship config"
mkdir -p /root/.config
[[ ! -f /root/.config/starship.toml ]] \
    && wget -qO /root/.config/starship.toml "$REPO_COMMON/starship.toml"

# =============================================================================
# 6. NVM + Node LTS + Direnv  [PVE only]
# =============================================================================
if [[ "$MODE" == "pve" ]]; then
    step "NVM + Node LTS"
    if [[ ! -d ~/.nvm ]]; then
        if git clone -q https://github.com/nvm-sh/nvm.git ~/.nvm 2>/dev/null; then
            export NVM_DIR="$HOME/.nvm"
            # shellcheck source=/dev/null
            . "$NVM_DIR/nvm.sh"
            nvm install --lts || warn "NVM LTS install failed"
            echo "  OK: NVM + Node LTS installed"
        else
            warn "NVM clone failed — skipping"
        fi
    fi

    step "Direnv"
    if ! command -v direnv &>/dev/null; then
        _tmp="$(mktemp -d)"
        if git clone -q https://github.com/direnv/direnv.git "$_tmp" 2>/dev/null \
            && (cd "$_tmp" && make -s install); then
            echo "  OK: Direnv installed"
        else
            warn "Direnv build failed — skipping"
        fi
        rm -rf "$_tmp"
    fi
fi

# =============================================================================
# 7. FiraCode Nerd Font
# =============================================================================
step "FiraCode Nerd Font"
FONT_DIR="/usr/local/share/fonts/nerdfonts"
if [[ ! -d "$FONT_DIR" ]] || [[ -z "$(ls -A "$FONT_DIR" 2>/dev/null)" ]]; then
    mkdir -p "$FONT_DIR"
    if wget -qO "$FONT_DIR/FiraCode.zip" \
        "https://github.com/ryanoasis/nerd-fonts/releases/download/v3.2.1/FiraCode.zip" 2>/dev/null \
        && unzip -qo "$FONT_DIR/FiraCode.zip" -d "$FONT_DIR" 2>/dev/null; then
        rm -f "$FONT_DIR/FiraCode.zip"
        fc-cache -f 2>/dev/null || true
        echo "  OK: FiraCode Nerd Font installed"
    else
        rm -f "$FONT_DIR/FiraCode.zip"
        warn "FiraCode Nerd Font install failed — skipping"
    fi
fi

# =============================================================================
# 8. nano syntax highlighting  (scopatz/nanorc)
# =============================================================================
step "nano syntax highlighting"
if [[ ! -d /root/.nano/.git ]]; then
    [[ -d /root/.nano ]] && rm -rf /root/.nano
    if git clone -q https://github.com/scopatz/nanorc.git /root/.nano 2>/dev/null; then
        printf "# nano syntax — auto-generated by init.sh\n" > /root/.nanorc
        for f in /root/.nano/*.nanorc; do
            [[ -f "$f" ]] && printf 'include "%s"\n' "$f" >> /root/.nanorc
        done
        echo "  OK: nano syntax installed"
    else
        warn "nano syntax clone failed — skipping"
    fi
fi

# =============================================================================
# 9. Configs from hyper-focused/Deb_Setup
# =============================================================================
step "Configs from repo"

# .bashrc + dotfiles
if ask_yn "Deploy shell configs (.bashrc, .tmux.conf, .gitconfig)?" "y"; then
    [[ -f /root/.bashrc && ! -f /root/.bashrc.orig ]] && cp /root/.bashrc /root/.bashrc.orig
    if wget -qO /root/.bashrc "$REPO_COMMON/.bashrc" 2>/dev/null; then
        for _dotfile in .tmux.conf .gitconfig; do
            wget -qO "/root/$_dotfile" "$REPO_COMMON/$_dotfile" 2>/dev/null \
                || warn "dotfile download failed: $_dotfile"
        done
        echo "  OK: .bashrc + dotfiles"
    else
        warn ".bashrc download failed"
    fi
else
    echo "  SKIP: shell configs"
fi

# htop + btop
if ask_yn "Deploy htop + btop configs?" "y"; then
    mkdir -p /root/.config/htop /root/.config/btop
    wget -qO /root/.config/htop/htoprc  "$REPO_COMMON/htop/htoprc" 2>/dev/null \
        || warn "htoprc download failed"
    wget -qO /root/.config/btop/btop.conf "$REPO_COMMON/btop/btop.conf" 2>/dev/null \
        || warn "btop.conf download failed"
    echo "  OK: htop + btop configs"
else
    echo "  SKIP: htop/btop configs"
fi

# sshd_config
SSHD="/etc/ssh/sshd_config"
if ask_yn "Deploy hardened sshd_config ($MODE)?" "y"; then
    _sshd_go=true
    if [[ ! -s /root/.ssh/authorized_keys ]]; then
        echo "  WARNING: /root/.ssh/authorized_keys is empty — key-only sshd will lock out password logins"
        if ! ask_yn "Deploy key-only sshd_config anyway?" "n"; then
            _sshd_go=false
            echo "  SKIP: sshd_config (add keys, then re-run)"
            NEEDS_ATTENTION+=("Add root SSH keys to /root/.ssh/authorized_keys, then re-run or deploy sshd_config manually")
        fi
    fi
    if [[ "$_sshd_go" == "true" ]] && confirm_overwrite "$SSHD" "sshd_config" "$_pre_sshd"; then
        # Ensure host keys exist (Debian 13 may omit RSA by default; our config needs both)
        if [[ ! -f /etc/ssh/ssh_host_ed25519_key ]]; then
            ssh-keygen -t ed25519 -f /etc/ssh/ssh_host_ed25519_key -N "" -q \
                && echo "  OK: generated ssh_host_ed25519_key" \
                || warn "failed to generate ED25519 host key"
        fi
        if [[ ! -f /etc/ssh/ssh_host_rsa_key ]]; then
            ssh-keygen -t rsa -b 4096 -f /etc/ssh/ssh_host_rsa_key -N "" -q \
                && echo "  OK: generated ssh_host_rsa_key (4096-bit)" \
                || warn "failed to generate RSA host key"
        fi
        [[ -f "$SSHD" && ! -f "${SSHD}.orig" ]] && cp "$SSHD" "${SSHD}.orig"
        if wget -qO "${SSHD}.new" "$REPO_MODE/sshd_config" 2>/dev/null; then
            if sshd -t -f "${SSHD}.new" 2>/dev/null; then
                mv "${SSHD}.new" "$SSHD"
                systemctl reload sshd 2>/dev/null || warn "sshd reload failed"
                echo "  OK: sshd_config applied and reloaded"
                NEEDS_ATTENTION+=("Keep this session open until you verify SSH on port 2211 with keys")
            else
                rm -f "${SSHD}.new"
                warn "sshd_config validation failed — keeping original"
            fi
        else
            warn "sshd_config download failed"
        fi
    fi
else
    echo "  SKIP: sshd_config"
fi

# =============================================================================
# 10. rsyslog remote forwarding
# =============================================================================
step "rsyslog remote forwarding"
_rsyslog_dst="/etc/rsyslog.d/99-remote.conf"
_deploy_rsyslog=false

if [[ -f "$_rsyslog_dst" ]]; then
    if confirm_overwrite "$_rsyslog_dst" "rsyslog-remote.conf" "$_pre_rsyslog"; then
        _deploy_rsyslog=true
    fi
elif ask_yn "Configure remote rsyslog forwarding (LibreNMS/syslog)?" "y"; then
    _deploy_rsyslog=true
else
    echo "  SKIP: rsyslog remote forwarding not configured"
fi

if [[ "$_deploy_rsyslog" == "true" ]]; then
    echo ""
    RSYSLOG_SERVER="$(ask_val "Remote syslog server IP (blank = skip)" "")"
    if [[ -n "$RSYSLOG_SERVER" ]]; then
        echo "  Minimum severity to forward:"
        echo "    1) debug  2) info  3) notice  4) warning [default]  5) err  6) crit"
        _sev_choice="$(ask_val "Choice" "4")"
        case "$_sev_choice" in
            1) RSYSLOG_SEVERITY="debug"   ;;
            2) RSYSLOG_SEVERITY="info"    ;;
            3) RSYSLOG_SEVERITY="notice"  ;;
            5) RSYSLOG_SEVERITY="err"     ;;
            6) RSYSLOG_SEVERITY="crit"    ;;
            *) RSYSLOG_SEVERITY="warning" ;;
        esac
        if wget -qO /tmp/rsyslog-remote.conf.new "$REPO_COMMON/rsyslog-remote.conf" 2>/dev/null; then
            sed -i \
                -e "s|RSYSLOG_SERVER|$RSYSLOG_SERVER|g" \
                -e "s|RSYSLOG_SEVERITY|$RSYSLOG_SEVERITY|g" \
                /tmp/rsyslog-remote.conf.new
            if [[ -s /tmp/rsyslog-remote.conf.new ]] \
                && ! grep -qE 'RSYSLOG_SERVER|RSYSLOG_SEVERITY' /tmp/rsyslog-remote.conf.new; then
                mv /tmp/rsyslog-remote.conf.new "$_rsyslog_dst"
                if systemctl restart rsyslog 2>/dev/null; then
                    echo "  OK: rsyslog — *.$RSYSLOG_SEVERITY → $RSYSLOG_SERVER:514 (UDP)"
                else
                    warn "rsyslog failed to restart — check: journalctl -xeu rsyslog"
                fi
            else
                rm -f /tmp/rsyslog-remote.conf.new
                warn "rsyslog config validation failed — not deployed"
            fi
        else
            warn "rsyslog template download failed"
        fi
    else
        echo "  SKIP: no remote server set — rsyslog-remote.conf not deployed"
        NEEDS_ATTENTION+=("Configure rsyslog forwarding: create /etc/rsyslog.d/99-remote.conf")
    fi
fi

# =============================================================================
# 11. sysctl tuning
# =============================================================================
step "sysctl tuning"
_sysctl_dst="/etc/sysctl.d/99-init.conf"
if ask_yn "Apply sysctl tuning ($MODE profile)?" "y"; then
    if confirm_overwrite "$_sysctl_dst" "sysctl.conf (99-init.conf)"; then
        if wget -qO "$_sysctl_dst" "$REPO_MODE/sysctl.conf" 2>/dev/null \
            && sysctl --system > /dev/null 2>&1; then
            echo "  OK: sysctl tuning applied → $_sysctl_dst"
        else
            warn "sysctl tuning failed — $_sysctl_dst may be incomplete"
        fi
    fi
else
    echo "  SKIP: sysctl tuning"
fi

# =============================================================================
# 12. zram config  [PVE only]
# =============================================================================
if [[ "$MODE" == "pve" ]]; then
    step "zram config (PVE)"
    _zram_cfg="/etc/default/zramswap"
    if ask_yn "Configure zramswap (lz4, 25% RAM)?" "y"; then
        if confirm_overwrite "$_zram_cfg" "zramswap" "$_pre_zram"; then
            [[ -f "$_zram_cfg" && ! -f "${_zram_cfg}.orig" ]] \
                && cp "$_zram_cfg" "${_zram_cfg}.orig"
            if wget -qO "$_zram_cfg" "$REPO_MODE/zramswap" 2>/dev/null \
                && systemctl restart zramswap 2>/dev/null; then
                echo "  OK: zramswap configured (lz4, 25% RAM)"
            else
                warn "zram config failed — check /etc/default/zramswap"
            fi
        fi
    else
        echo "  SKIP: zramswap"
    fi
fi

# =============================================================================
# 13. Monitoring — SNMP extends preferred; check_mk only where it wins (PVE)
# =============================================================================
step "Monitoring setup"

echo "  Preference: SNMP extends + collectd push. check_mk only for PVE-specific apps."
if [[ "$MODE" == "debian" ]]; then
    echo "  Debian VM: SNMP extends cover distro/DMI/osupdate/chrony/softnet/entropy — no check_mk."
else
    echo "  PVE: SNMP for host metrics; check_mk for proxmox + rrdcached + temperature."
fi
echo "  Enter accepts defaults; blank collectd IP skips that component."
echo ""

if ! ask_yn "Configure monitoring stack?" "y"; then
    echo "  SKIP: entire monitoring step"
    NEEDS_ATTENTION+=("Monitoring not configured — re-run init or set up snmpd/collectd manually")
else

NEEDS_ATTENTION+=("SNMP MIB resolution: install snmp-mibs-downloader manually and verify snmpwalk shows names not numeric IDs (v1.7 Trixie regression)")

# ── Component opt-ins ─────────────────────────────────────────────────────────
_deploy_snmpd=false
_deploy_collectd=false
_deploy_checkmk=false
_enable_smart=false
_enable_postfix_ext=false

if ask_yn "Deploy snmpd + SNMP extends (preferred path)?" "y"; then
    if confirm_overwrite /etc/snmp/snmpd.conf "snmpd.conf" "$_pre_snmpd"; then
        _deploy_snmpd=true
    fi
fi

if ask_yn "Deploy collectd → LibreNMS (UDP 25826)?" "y"; then
    if confirm_overwrite /etc/collectd/collectd.conf "collectd.conf" "$_pre_collectd"; then
        _deploy_collectd=true
    fi
fi

# check_mk: PVE default Y (proxmox/rrdcached/temp); Debian default N (not needed)
if [[ "$MODE" == "pve" ]]; then
    # Required for LibreNMS Proxmox application (check_mk agent-local proxmox plugin)
    if ask_yn "Install check_mk agent (required for LibreNMS Proxmox app + rrdcached/temp)?" "y"; then
        _deploy_checkmk=true
    fi
else
    if ask_yn "Install check_mk agent on this VM? (usually N — SNMP covers it)" "n"; then
        _deploy_checkmk=true
    fi
fi

# ── Parameters ────────────────────────────────────────────────────────────────
SNMP_COMMUNITY="public"
SNMP_SOURCES=""
# Default LibreNMS poller (override at prompt if needed)
LIBRENMS_IP="172.93.1.52"
SYS_LOCATION="Unknown"
SYS_CONTACT="root@localhost"
COLLECTD_SERVER=""
COLLECTD_HOSTNAME="$(hostname -f 2>/dev/null || hostname)"

if [[ "$_deploy_snmpd" == "true" ]]; then
    echo ""
    echo "  SNMP parameters (Enter = default where shown):"
    echo "  LibreNMS must reach this host on UDP 161 — allow its real poller IP (not 127.0.0.1)."
    SNMP_COMMUNITY="$(ask_val "SNMP community string" "public")"

    # Required: at least one reachable LibreNMS poller address
    while true; do
        LIBRENMS_IP="$(ask_val "LibreNMS poller IP (required)" "${LIBRENMS_IP}")"
        LIBRENMS_IP="${LIBRENMS_IP// /}"  # strip spaces
        if [[ -z "$LIBRENMS_IP" ]]; then
            echo "  ERROR: LibreNMS poller IP is required for SNMP"
            LIBRENMS_IP="172.93.1.52"
            continue
        fi
        if [[ "$LIBRENMS_IP" == "127.0.0.1" || "$LIBRENMS_IP" == "::1" || "$LIBRENMS_IP" == "localhost" ]]; then
            echo "  ERROR: localhost is not usable — LibreNMS polls over the network"
            LIBRENMS_IP="172.93.1.52"
            continue
        fi
        break
    done

    # Mgmt range covering LibreNMS + related hosts (override/clear at prompt if needed)
    _extra_src="$(ask_val "Additional SNMP sources (CIDR/IP, space-separated)" "172.93.0.0/23")"
    SNMP_SOURCES="$LIBRENMS_IP"
    [[ -n "$_extra_src" ]] && SNMP_SOURCES="$SNMP_SOURCES $_extra_src"

    SYS_LOCATION="$(ask_val "sysLocation" "Unknown")"
    SYS_CONTACT="$(ask_val "sysContact" "root@localhost")"

    if [[ "$MODE" == "pve" ]]; then
        echo ""
        echo "  SNMP extend options (sane defaults for bare metal):"
        if ask_yn "Configure SMART disk extend (auto-detect drives + cron)?" "y"; then
            _enable_smart=true
        fi
        if _pkg_installed postfix || [[ -x /usr/sbin/postqueue ]]; then
            if ask_yn "Enable postfix SNMP extends (queues + pflogsumm)?" "y"; then
                _enable_postfix_ext=true
            fi
        else
            echo "  SKIP: postfix not installed — postfix extends off"
        fi
    fi
fi

if [[ "$_deploy_collectd" == "true" ]]; then
    echo ""
    echo "  Collectd (remote LibreNMS only, 60s interval):"
    COLLECTD_HOSTNAME="$(ask_val "Collectd hostname" "$COLLECTD_HOSTNAME")"
    # Default collectd target to the same LibreNMS host when SNMP already asked for it
    _cd_default="${LIBRENMS_IP}"
    COLLECTD_SERVER="$(ask_val "LibreNMS / collectd server IP (blank = skip)" "${_cd_default}")"
fi

# ── LibreNMS agent clone ──────────────────────────────────────────────────────
AGENT_DIR="/opt/librenms-agent"
AGENT_REPO="https://github.com/librenms/librenms-agent.git"
_need_agent=false
[[ "$_deploy_snmpd" == "true" || "$_deploy_checkmk" == "true" ]] && _need_agent=true

if [[ "$_need_agent" == "true" ]]; then
    _pin_file="$(wget -qO- "$REPO_RAW/librenms-agent.pin" 2>/dev/null || true)"
    AGENT_PIN_SHA="$(echo "$_pin_file" | grep '^SHA=' | cut -d= -f2)"
    AGENT_PIN_DATE="$(echo "$_pin_file" | grep '^DATE=' | cut -d= -f2)"

    if [[ -z "$AGENT_PIN_SHA" ]]; then
        warn "could not read librenms-agent.pin — skipping agent-backed monitoring"
        _deploy_snmpd=false
        _deploy_checkmk=false
    else
        echo "  librenms-agent pin: $AGENT_PIN_SHA ($AGENT_PIN_DATE)"
        if [[ ! -d "$AGENT_DIR/.git" ]]; then
            mkdir -p "$AGENT_DIR"
            if git -C "$AGENT_DIR" init -q \
                && git -C "$AGENT_DIR" remote add origin "$AGENT_REPO" 2>/dev/null \
                && git -C "$AGENT_DIR" fetch --depth=1 origin "$AGENT_PIN_SHA" 2>/dev/null \
                && git -C "$AGENT_DIR" checkout FETCH_HEAD 2>/dev/null; then
                echo "  OK: librenms-agent cloned at $AGENT_PIN_SHA"
            else
                warn "librenms-agent clone failed"
                _deploy_snmpd=false
                _deploy_checkmk=false
            fi
        else
            _current="$(git -C "$AGENT_DIR" rev-parse HEAD 2>/dev/null || true)"
            if [[ "$_current" != "$AGENT_PIN_SHA" ]]; then
                if git -C "$AGENT_DIR" fetch --depth=1 origin "$AGENT_PIN_SHA" 2>/dev/null \
                    && git -C "$AGENT_DIR" checkout FETCH_HEAD 2>/dev/null; then
                    echo "  OK: librenms-agent updated to $AGENT_PIN_SHA"
                else
                    warn "librenms-agent update failed — using existing tree"
                fi
            else
                echo "  SKIP: librenms-agent already at pinned commit"
            fi
        fi
    fi
fi

# ── SNMP extend scripts ───────────────────────────────────────────────────────
if [[ "$_deploy_snmpd" == "true" && -d "$AGENT_DIR/snmp" ]]; then
    install -m 755 -o root -g root "$AGENT_DIR/snmp/distro" /usr/bin/distro

    _ext_list="$(wget -qO- "$REPO_MODE/monitoring/snmp-extends" 2>/dev/null \
        | grep -v '^#' | grep -v '^$' | awk '{print $1}' || true)"

    # Filter optional extends based on prompts
    _all_extends=""
    for _script in $_ext_list; do
        case "$_script" in
            smart)
                [[ "$_enable_smart" == "true" ]] || continue
                ;;
            postfix-queues|postfixdetailed)
                [[ "$_enable_postfix_ext" == "true" ]] || continue
                ;;
        esac
        _all_extends="$_all_extends $_script"
    done
    _ext_ok=0
    for _script in $_all_extends; do
        _dst="${_script%.sh}"
        if [[ -f "$AGENT_DIR/snmp/$_script" ]]; then
            install -m 755 -o root -g Debian-snmp "$AGENT_DIR/snmp/$_script" "/etc/snmp/$_dst" 2>/dev/null \
                || install -m 755 -o root -g root "$AGENT_DIR/snmp/$_script" "/etc/snmp/$_dst"
            _ext_ok=$((_ext_ok + 1))
        else
            warn "extend script not found: $_script"
        fi
    done
    echo "  OK: $_ext_ok SNMP extend scripts installed"

    # SMART: config + cache + cron (extend is slow without -u cache refresh)
    if [[ "$_enable_smart" == "true" ]]; then
        SMART_CFG="/etc/snmp/smart.config"
        mkdir -p /var/cache/smart
        chown root:Debian-snmp /var/cache/smart 2>/dev/null || true
        _regen_smart=false
        if [[ ! -f "$SMART_CFG" ]]; then
            _regen_smart=true
        elif ask_yn "Regenerate smart.config (auto-detect disks)?" "n"; then
            _regen_smart=true
        fi
        if [[ "$_regen_smart" == "true" ]]; then
            if wget -qO "$SMART_CFG" "$REPO_MODE/monitoring/smart.config" 2>/dev/null; then
                _disk_n=0
                while IFS= read -r _dev; do
                    _name="$(basename "$_dev")"
                    if [[ "$_dev" == *nvme* ]]; then
                        echo "$_name $_dev -d nvme" >> "$SMART_CFG"
                    else
                        echo "$_name $_dev -d sat" >> "$SMART_CFG"
                    fi
                    _disk_n=$((_disk_n + 1))
                done < <(lsblk -dno NAME,TYPE 2>/dev/null | awk '$2=="disk"{print "/dev/"$1}' || true)
                chown root:Debian-snmp "$SMART_CFG" 2>/dev/null || chown root:root "$SMART_CFG"
                chmod 640 "$SMART_CFG"
                echo "  OK: smart.config — $_disk_n disk(s) detected"
                if [[ "$_disk_n" -eq 0 ]]; then
                    warn "no disks auto-detected — edit /etc/snmp/smart.config manually"
                fi
                NEEDS_ATTENTION+=("Review /etc/snmp/smart.config (labels, -d sat vs nvme vs megaraid)")
            else
                warn "smart.config template download failed"
            fi
        else
            echo "  SKIP: keeping existing smart.config"
        fi
        cat > /etc/cron.d/librenms-smart <<'EOF'
# Managed by hyper-focused/Deb_Setup — refresh SMART SNMP cache
SHELL=/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
*/5 * * * * root [ -x /etc/snmp/smart ] && /etc/snmp/smart -u >/dev/null 2>&1
EOF
        chmod 644 /etc/cron.d/librenms-smart
        /etc/snmp/smart -u >/dev/null 2>&1 || true
        echo "  OK: SMART cron (/etc/cron.d/librenms-smart) + initial cache update"
    fi

    # Postfix detailed cache dir
    if [[ "$_enable_postfix_ext" == "true" ]]; then
        mkdir -p /var/cache
        touch /var/cache/postfixdetailed 2>/dev/null || true
        chown root:Debian-snmp /var/cache/postfixdetailed 2>/dev/null || true
        echo "  OK: postfixdetailed cache ready"
    fi

fi

# ── snmpd.conf ────────────────────────────────────────────────────────────────
if [[ "$_deploy_snmpd" == "true" ]]; then
    if wget -qO /tmp/snmpd.conf.new "$REPO_MODE/monitoring/snmpd.conf" 2>/dev/null; then
        # Strip optional extend lines not selected
        if [[ "$_enable_smart" != "true" ]]; then
            sed -i '/^extend smart/d' /tmp/snmpd.conf.new
        fi
        if [[ "$_enable_postfix_ext" != "true" ]]; then
            sed -i '/^extend mailq/d;/^extend postfixdetailed/d' /tmp/snmpd.conf.new
        fi

        # Build com2sec / com2sec6 lines from allowed sources (no silent world-open)
        _com2sec_block=""
        for _src in $SNMP_SOURCES; do
            if [[ "$_src" == "default" ]]; then
                if ask_yn "Allow SNMP from ANY source (com2sec default) — not recommended?" "n"; then
                    _com2sec_block+="com2sec readonly  default  ${SNMP_COMMUNITY}"$'\n'
                else
                    warn "skipped SNMP source 'default'"
                fi
                continue
            fi
            if [[ "$_src" == *:* ]]; then
                _com2sec_block+="com2sec6 readonly  ${_src}  ${SNMP_COMMUNITY}"$'\n'
            else
                _com2sec_block+="com2sec readonly  ${_src}  ${SNMP_COMMUNITY}"$'\n'
            fi
        done
        if [[ -z "$_com2sec_block" ]]; then
            warn "no valid SNMP sources after filtering — refusing to deploy open/localhost-only snmpd"
            rm -f /tmp/snmpd.conf.new
            NEEDS_ATTENTION+=("snmpd not deployed — provide LibreNMS poller IP and re-run monitoring step")
        else
        export _com2sec_block
        awk '
            /#COM2SEC_BLOCK#/ { printf "%s", ENVIRON["_com2sec_block"]; next }
            { print }
        ' /tmp/snmpd.conf.new > /tmp/snmpd.conf.injected \
            && mv /tmp/snmpd.conf.injected /tmp/snmpd.conf.new

        sed -i \
            -e "s|SYSLOCATION|$SYS_LOCATION|g" \
            -e "s|SYSCONTACT|$SYS_CONTACT|g" \
            /tmp/snmpd.conf.new

        if [[ -s /tmp/snmpd.conf.new ]] \
            && grep -qE '^com2sec' /tmp/snmpd.conf.new \
            && ! grep -qE 'COM2SEC_BLOCK|SYSLOCATION|SYSCONTACT|SNMP_COMMUNITY' /tmp/snmpd.conf.new; then
            [[ -f /etc/snmp/snmpd.conf && ! -f /etc/snmp/snmpd.conf.orig ]] \
                && cp /etc/snmp/snmpd.conf /etc/snmp/snmpd.conf.orig
            mv /tmp/snmpd.conf.new /etc/snmp/snmpd.conf
            chown root:Debian-snmp /etc/snmp/snmpd.conf 2>/dev/null || chown root:root /etc/snmp/snmpd.conf
            chmod 640 /etc/snmp/snmpd.conf
            if systemctl enable snmpd 2>/dev/null && systemctl restart snmpd 2>/dev/null; then
                echo "  OK: snmpd.conf applied (LibreNMS: $LIBRENMS_IP; sources: $SNMP_SOURCES)"
            else
                warn "snmpd failed to restart — check: journalctl -xeu snmpd"
            fi
            NEEDS_ATTENTION+=("Firewall: allow SNMP UDP 161 from LibreNMS ($LIBRENMS_IP) to this host")
        else
            rm -f /tmp/snmpd.conf.new /tmp/snmpd.conf.injected
            warn "snmpd.conf validation failed — original kept"
            NEEDS_ATTENTION+=("Fix /etc/snmp/snmpd.conf — validation failed")
        fi
        fi  # end _com2sec_block non-empty
    else
        warn "snmpd.conf template download failed"
    fi
fi

# ── check_mk (PVE-focused; optional on Debian) ────────────────────────────────
# LibreNMS Proxmox app uses the check_mk agent-local "proxmox" plugin (PVE API).
# That is intentional — there is no SNMP extend equivalent. Always install it on PVE.
if [[ "$_deploy_checkmk" == "true" && -f "$AGENT_DIR/check_mk_agent" ]]; then
    install -m 755 -o root -g root "$AGENT_DIR/check_mk_agent" /usr/bin/check_mk_agent
    mkdir -p /usr/lib/check_mk_agent/local /usr/lib/check_mk_agent/plugins
    install -m 644 -o root -g root "$AGENT_DIR/check_mk.socket"   /etc/systemd/system/
    install -m 644 -o root -g root "$AGENT_DIR/check_mk@.service" /etc/systemd/system/
    systemctl daemon-reload
    systemctl enable --now check_mk.socket 2>/dev/null || systemctl start check_mk.socket 2>/dev/null \
        || warn "check_mk.socket failed to start"
    echo "  OK: check_mk agent + socket"

    _plugin_list="$(wget -qO- "$REPO_MODE/monitoring/checkmk-plugins" 2>/dev/null \
        | grep -v '^#' | grep -v '^$' | awk '{print $1}' || true)"
    # PVE: force-include proxmox even if the remote list fetch fails or omits it
    if [[ "$MODE" == "pve" ]]; then
        if ! printf '%s\n' $_plugin_list | grep -qx 'proxmox'; then
            _plugin_list="proxmox $_plugin_list"
        fi
        # proxmox plugin needs PVE Perl API modules (shipped with Proxmox)
        if ! perl -e 'use PVE::APIClient::LWP; use PVE::AccessControl; use PVE::INotify' 2>/dev/null; then
            warn "PVE Perl modules missing for proxmox check_mk plugin (PVE::APIClient::LWP etc.)"
            NEEDS_ATTENTION+=("Install Proxmox API Perl modules so check_mk proxmox plugin works (pve-manager / libpve-*)")
        fi
    fi

    _plg_ok=0
    for _plugin in $_plugin_list; do
        if [[ "$_plugin" == "temperature" ]]; then
            if wget -qO "/usr/lib/check_mk_agent/local/$_plugin" \
                "$REPO_MODE/monitoring/$_plugin" 2>/dev/null; then
                chmod 755 "/usr/lib/check_mk_agent/local/$_plugin"
                _plg_ok=$((_plg_ok + 1))
            else
                warn "temperature plugin download failed"
            fi
        elif [[ -f "$AGENT_DIR/agent-local/$_plugin" ]]; then
            install -m 755 -o root -g root "$AGENT_DIR/agent-local/$_plugin" \
                "/usr/lib/check_mk_agent/local/$_plugin"
            _plg_ok=$((_plg_ok + 1))
            if [[ "$_plugin" == "proxmox" ]]; then
                echo "  OK: check_mk proxmox plugin (LibreNMS Proxmox app via agent)"
            fi
        else
            warn "check_mk plugin not found: $_plugin"
        fi
    done
    echo "  OK: $_plg_ok check_mk plugins installed"
    if [[ "$_plg_ok" -gt 0 ]]; then
        NEEDS_ATTENTION+=("Firewall: allow check_mk (TCP 6556) from LibreNMS only")
        if [[ "$MODE" == "pve" ]]; then
            NEEDS_ATTENTION+=("LibreNMS: enable Applications → Proxmox (and Unix Agent) for this host — uses check_mk proxmox plugin")
        fi
    fi
    # rrdcached plugin expects /var/run/rrdcached.sock on PVE
    if [[ "$MODE" == "pve" ]] && [[ -x /usr/lib/check_mk_agent/local/rrdcached ]]; then
        if [[ ! -S /var/run/rrdcached.sock && ! -S /run/rrdcached.sock ]]; then
            NEEDS_ATTENTION+=("rrdcached socket not found — enable rrdcached on PVE if you want that check_mk plugin")
        fi
    fi
fi

# ── collectd.conf ─────────────────────────────────────────────────────────────
if [[ "$_deploy_collectd" == "true" ]]; then
    if [[ -n "$COLLECTD_SERVER" ]]; then
        if wget -qO /tmp/collectd.conf.new "$REPO_MODE/monitoring/collectd.conf" 2>/dev/null; then
            sed -i \
                -e "s|COLLECTD_HOSTNAME|$COLLECTD_HOSTNAME|g" \
                -e "s|COLLECTD_SERVER|$COLLECTD_SERVER|g" \
                /tmp/collectd.conf.new
            # PVE: disable sensors plugin if lm-sensors has no chips (avoids log spam)
            if [[ "$MODE" == "pve" ]] && grep -q '^LoadPlugin sensors' /tmp/collectd.conf.new; then
                if ! command -v sensors &>/dev/null \
                    || ! sensors -j &>/dev/null \
                    || [[ "$(sensors -j 2>/dev/null | wc -c)" -lt 20 ]]; then
                    sed -i 's/^LoadPlugin sensors/# LoadPlugin sensors  # no sensors detected/' \
                        /tmp/collectd.conf.new
                    echo "  NOTE: collectd sensors plugin disabled (no usable sensors data)"
                fi
            fi
            if [[ -s /tmp/collectd.conf.new ]] \
                && ! grep -qE 'COLLECTD_HOSTNAME|COLLECTD_SERVER' /tmp/collectd.conf.new; then
                [[ -f /etc/collectd/collectd.conf && ! -f /etc/collectd/collectd.conf.orig ]] \
                    && cp /etc/collectd/collectd.conf /etc/collectd/collectd.conf.orig
                mkdir -p /etc/collectd/collectd.conf.d
                mv /tmp/collectd.conf.new /etc/collectd/collectd.conf
                if systemctl enable collectd 2>/dev/null && systemctl restart collectd 2>/dev/null; then
                    echo "  OK: collectd.conf applied (→ $COLLECTD_SERVER:25826)"
                else
                    warn "collectd failed to restart — check: journalctl -xeu collectd"
                    NEEDS_ATTENTION+=("collectd failed to start — fix config then: systemctl restart collectd")
                fi
            else
                rm -f /tmp/collectd.conf.new
                warn "collectd.conf validation failed — not deployed"
            fi
        else
            warn "collectd.conf template download failed"
        fi
    else
        echo "  SKIP: no collectd server IP — collectd.conf not deployed"
        NEEDS_ATTENTION+=("Configure collectd: set LibreNMS server IP in /etc/collectd/collectd.conf")
    fi
fi

fi  # end monitoring top-level opt-in

# =============================================================================
# 14. Enable mode-appropriate services (fully-configured host)
# =============================================================================
step "Enable host services"
_enable_svc() {
    local _svc="$1"
    if systemctl cat "${_svc}.service" &>/dev/null; then
        if systemctl enable --now "${_svc}.service" 2>/dev/null; then
            echo "  OK: ${_svc} enabled"
            return 0
        fi
        warn "could not enable ${_svc}"
        return 1
    fi
    return 0
}

if [[ "$MODE" == "pve" ]]; then
    _pkg_installed rasdaemon && _enable_svc rasdaemon
    _pkg_installed lldpd && _enable_svc lldpd
    _pkg_installed zfs-zed && _enable_svc zfs-zed
    command -v chronyc &>/dev/null && _enable_svc chrony
else
    _pkg_installed chrony && _enable_svc chrony
    _pkg_installed qemu-guest-agent && _enable_svc qemu-guest-agent
fi

if systemctl is-active --quiet snmpd 2>/dev/null; then
    echo "  OK: snmpd is active"
fi
if systemctl is-active --quiet collectd 2>/dev/null; then
    echo "  OK: collectd is active"
fi
if systemctl is-active --quiet check_mk.socket 2>/dev/null; then
    echo "  OK: check_mk.socket is active"
fi

echo "  Host service pass complete"

# =============================================================================
# Cleanup
# =============================================================================
step "Cleanup"
apt-get autoremove -y -qq > /dev/null 2>&1
apt-get clean -q

# =============================================================================
# Done
# =============================================================================

# Always-present reminders
NEEDS_ATTENTION+=(
    "Set git identity: git config --global user.name 'Your Name' && git config --global user.email 'you@example.com'"
    "Ensure port 2211 is allowed in firewall/host rules for admin SSH access"
)

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║   ALL DONE  —  $(date '+%Y-%m-%d %H:%M')                   ║"
echo "╠══════════════════════════════════════════════════╣"
echo "║  Log: $LOGFILE"
echo "╚══════════════════════════════════════════════════╝"

# ── Warnings / failures ───────────────────────────────────────────────────────
if [[ ${#FAILURES[@]} -gt 0 ]]; then
    echo ""
    echo "┌─ WARNINGS / FAILURES ─────────────────────────────────────┐"
    for _item in "${FAILURES[@]}"; do
        echo "│  ✗ $_item"
    done
    echo "└───────────────────────────────────────────────────────────┘"
fi

# ── Post-install attention list ───────────────────────────────────────────────
if [[ ${#NEEDS_ATTENTION[@]} -gt 0 ]]; then
    echo ""
    echo "┌─ ACTION REQUIRED ─────────────────────────────────────────┐"
    for _item in "${NEEDS_ATTENTION[@]}"; do
        echo "│  • $_item"
    done
    echo "└───────────────────────────────────────────────────────────┘"
fi

echo ""
echo "Next steps:"
echo "  source ~/.bashrc       # activate aliases & prompt"
[[ "$MODE" == "pve" ]] && echo "  nvm use --lts          # activate Node LTS"
echo "  tmux new -s main       # start persistent session"
echo "  bat /etc/hosts         # test bat theme"
echo "  nano test.py           # test syntax highlighting"
echo ""
echo "Open a NEW terminal to see Starship + Nerd Fonts."
