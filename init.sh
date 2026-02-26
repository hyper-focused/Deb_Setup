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
_pre_sshd=false;     _pkg_installed openssh-server && _pre_sshd=true
_pre_snmpd=false;    _pkg_installed snmpd          && _pre_snmpd=true
_pre_snmptrapd=false; _pkg_installed snmptrapd     && _pre_snmptrapd=true
_pre_collectd=false; _pkg_installed collectd        && _pre_collectd=true
_pre_zram=false;     _pkg_installed zram-tools      && _pre_zram=true

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

# ── Package lists ─────────────────────────────────────────────────────────────

# Installed on both PVE and Debian
# Note: packages pre-installed by PVE (pve-manager/qemu-server deps, Debian standard task)
# are omitted here and listed in DEBIAN_EXTRA_PKGS instead.
COMMON_PKGS=(
    # Shell & terminal
    bash-completion btop htop screen tmux

    # Text / file tools
    bat bc git-delta fd-find fzf jq pv
    ripgrep shfmt sqlite3 tree ugrep unzip
    vivid w3m whois xz-utils yamllint yq zip

    # Network
    curl ethtool fail2ban ipset lsof mtr
    net-tools nethogs nload nmap snmp snmpd
    tcpdump

    # System
    duf iperf3 lsb-release
    mosh parted pigz plocate strace sysstat xfsprogs

    # Dev & scripting
    build-essential git pipx

    # Monitoring (both modes send to collectd server, get polled via SNMP)
    collectd

    # Misc
    dtach nano ncdu starship tig zoxide
)

# PVE-only extras  (bare metal)
PVE_EXTRA_PKGS=(
    # Hardware & firmware
    # (dmidecode, hdparm, pciutils, smartmontools, usbutils are pre-installed by PVE)
    amd64-microcode
    intel-microcode
    fdutils
    fio
    inetutils-telnet
    ipmitool
    ipmiutil
    lm-sensors
    lsscsi
    mbw
    minicom
    nvme-cli
    nvtop
    openipmi
    sg3-utils
    stress-ng

    # Storage & filesystem
    libguestfs-tools
    ntfs-3g

    # Network & routing
    # (certbot omitted: PVE manages ACME/TLS certs via its own web UI)
    frr
    frr-pythontools

    # Monitoring (PVE-extra: richer plugins, trapd, collectd-utils)
    snmptrapd
    collectd-utils
    pflogsumm

    # Scripting & dev
    cpanminus
    cpuinfo
    cstream
    faketime
    imagemagick
    python3-json5
    ruby

    # PVE-specific
    # (proxmox-firewall omitted: tech-preview Recommends only; pve-firewall is pre-installed)
    rsyslog
    virt-manager
    virtiofsd
    xterm
    zram-tools
)

# Debian-only extras  (QEMU VM)
# Includes packages that are pre-installed by PVE but absent on a minimal Debian install
DEBIAN_EXTRA_PKGS=(
    qemu-guest-agent   # essential: proper shutdown, snapshots, IP reporting

    # Pre-installed on PVE (pve-manager / qemu-server / Debian standard task deps)
    bind9-dnsutils  # dig, nslookup, host
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
apt-get -q update
DEBIAN_FRONTEND=noninteractive apt-get -y -q full-upgrade

# =============================================================================
# 2. Package installation
# =============================================================================
step "Common packages (${#COMMON_PKGS[@]})"
echo "  Installing ${#COMMON_PKGS[@]} packages..."
if ! DEBIAN_FRONTEND=noninteractive apt-get -y -q install "${COMMON_PKGS[@]}" 2>/dev/null; then
    echo "  Batch install failed — retrying individually..."
    for _pkg in "${COMMON_PKGS[@]}"; do
        DEBIAN_FRONTEND=noninteractive apt-get -y -qq install "$_pkg" 2>/dev/null \
            || warn "Package unavailable: $_pkg"
    done
fi

if [[ "$MODE" == "pve" ]]; then
    step "PVE-specific packages (${#PVE_EXTRA_PKGS[@]}, bare metal)"
    _pve_ok=0; _pve_fail=0
    for _pkg in "${PVE_EXTRA_PKGS[@]}"; do
        if DEBIAN_FRONTEND=noninteractive apt-get -y -qq install "$_pkg" 2>/dev/null; then
            _pve_ok=$((_pve_ok + 1))
        else
            warn "Package unavailable: $_pkg"
            _pve_fail=$((_pve_fail + 1))
        fi
    done
    echo "  OK: $_pve_ok installed, $_pve_fail failed"
    # Initialise hardware sensor detection (non-interactive, updates /etc/modules)
    sensors-detect --auto > /dev/null 2>&1 \
        || warn "sensors-detect failed — run manually when convenient"
else
    step "Debian-specific packages (QEMU VM)"
    _qga_was_active=false
    systemctl is-active --quiet qemu-guest-agent 2>/dev/null && _qga_was_active=true
    _deb_ok=0; _deb_fail=0
    for _pkg in "${DEBIAN_EXTRA_PKGS[@]}"; do
        if DEBIAN_FRONTEND=noninteractive apt-get -y -qq install "$_pkg" 2>/dev/null; then
            _deb_ok=$((_deb_ok + 1))
        else
            warn "Package unavailable: $_pkg"
            _deb_fail=$((_deb_fail + 1))
        fi
    done
    echo "  OK: $_deb_ok installed, $_deb_fail failed"
    if [[ "$_qga_was_active" == "false" ]]; then
        systemctl enable --now qemu-guest-agent 2>/dev/null \
            || warn "qemu-guest-agent enable failed — may already be handled by VM template"
    fi
fi

# fail2ban: disable until manually configured (default jail watches port 22)
systemctl disable --now fail2ban 2>/dev/null || true
echo "  NOTE: fail2ban disabled — configure jail.d/sshd.conf for port 2211 first"
NEEDS_ATTENTION+=("Configure fail2ban: create /etc/fail2ban/jail.d/sshd.conf to protect port 2211, then: systemctl enable --now fail2ban")

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
    git clone -q --depth=1 https://github.com/eth-p/bat-extras.git "$_tmp"
    bash "$_tmp/build.sh" --install --prefix=/usr/local > /dev/null
    rm -rf "$_tmp"
    echo "  OK: bat-extras installed"
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
        git clone -q https://github.com/nvm-sh/nvm.git ~/.nvm
        export NVM_DIR="$HOME/.nvm"
        # shellcheck source=/dev/null
        . "$NVM_DIR/nvm.sh"
        nvm install --lts || warn "NVM LTS install failed"
        echo "  OK: NVM + Node LTS installed"
    fi

    step "Direnv"
    if ! command -v direnv &>/dev/null; then
        _tmp="$(mktemp -d)"
        git clone -q https://github.com/direnv/direnv.git "$_tmp"
        (cd "$_tmp" && make -s install) || warn "Direnv build failed"
        rm -rf "$_tmp"
        echo "  OK: Direnv installed"
    fi
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
    fc-cache -f
    echo "  OK: FiraCode Nerd Font installed"
fi

# =============================================================================
# 8. nano syntax highlighting  (scopatz/nanorc)
# =============================================================================
step "nano syntax highlighting"
if [[ ! -d /root/.nano/.git ]]; then
    [[ -d /root/.nano ]] && rm -rf /root/.nano
    git clone -q https://github.com/scopatz/nanorc.git /root/.nano
    printf "# nano syntax — auto-generated by init.sh\n" > /root/.nanorc
    for f in /root/.nano/*.nanorc; do
        [[ -f "$f" ]] && printf 'include "%s"\n' "$f" >> /root/.nanorc
    done
    echo "  OK: nano syntax installed"
fi

# =============================================================================
# 9. Configs from hyper-focused/Deb_Setup
# =============================================================================
step "Configs from repo"

# .bashrc + dotfiles
[[ -f /root/.bashrc && ! -f /root/.bashrc.orig ]] && cp /root/.bashrc /root/.bashrc.orig
wget -qO /root/.bashrc "$REPO_COMMON/.bashrc"
for _dotfile in .tmux.conf .gitconfig .vimrc; do
    wget -qO "/root/$_dotfile" "$REPO_COMMON/$_dotfile"
done
echo "  OK: .bashrc + dotfiles"

# htop + btop
mkdir -p /root/.config/htop /root/.config/btop
wget -qO /root/.config/htop/htoprc  "$REPO_COMMON/htop/htoprc"
wget -qO /root/.config/btop/btop.conf "$REPO_COMMON/btop/btop.conf"
echo "  OK: htop + btop configs"

# sshd_config
SSHD="/etc/ssh/sshd_config"
if confirm_overwrite "$SSHD" "sshd_config" "$_pre_sshd"; then
    [[ -f "$SSHD" && ! -f "${SSHD}.orig" ]] && cp "$SSHD" "${SSHD}.orig"
    wget -qO "${SSHD}.new" "$REPO_MODE/sshd_config"
    if sshd -t -f "${SSHD}.new" 2>/dev/null; then
        mv "${SSHD}.new" "$SSHD"
        systemctl reload sshd
        echo "  OK: sshd_config applied and reloaded"
    else
        rm -f "${SSHD}.new"
        warn "sshd_config validation failed — keeping original"
    fi
fi

# =============================================================================
# 10. sysctl tuning
# =============================================================================
step "sysctl tuning"
_sysctl_dst="/etc/sysctl.d/99-init.conf"
if confirm_overwrite "$_sysctl_dst" "sysctl.conf (99-init.conf)"; then
    if wget -qO "$_sysctl_dst" "$REPO_MODE/sysctl.conf" 2>/dev/null \
        && sysctl --system > /dev/null; then
        echo "  OK: sysctl tuning applied → $_sysctl_dst"
    else
        warn "sysctl tuning failed — $_sysctl_dst may be incomplete"
    fi
fi

# =============================================================================
# 11. zram config  [PVE only]
# =============================================================================
if [[ "$MODE" == "pve" ]]; then
    step "zram config (PVE)"
    _zram_cfg="/etc/default/zramswap"
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
fi

# =============================================================================
# 12. Monitoring — LibreNMS agent, SNMP extends, collectd
# =============================================================================
step "Monitoring setup"

DEBIAN_FRONTEND=noninteractive apt-get -y -qq install snmp-mibs-downloader 2>/dev/null \
    || warn "snmp-mibs-downloader unavailable — SNMP MIB names will show as numeric OIDs"

# Collect values needed for config substitution
echo ""
read -rp "  SNMP community string [default: public]: " SNMP_COMMUNITY
SNMP_COMMUNITY="${SNMP_COMMUNITY:-public}"
read -rp "  sysLocation (e.g. 'DC1 Rack 4'): " SYS_LOCATION
SYS_LOCATION="${SYS_LOCATION:-Unknown}"
read -rp "  sysContact (e.g. 'noc@example.com'): " SYS_CONTACT
SYS_CONTACT="${SYS_CONTACT:-root@localhost}"
read -rp "  Collectd / LibreNMS server IP: " COLLECTD_SERVER
COLLECTD_SERVER="${COLLECTD_SERVER:-127.0.0.1}"
COLLECTD_HOSTNAME="$(hostname -f 2>/dev/null || hostname)"

# ── LibreNMS agent — pinned to commit SHA from librenms-agent.pin ─────────────
AGENT_DIR="/opt/librenms-agent"
AGENT_REPO="https://github.com/librenms/librenms-agent.git"

# Read pinned SHA from our repo (source of truth for version control)
_pin_file="$(wget -qO- "$REPO_RAW/librenms-agent.pin")"
AGENT_PIN_SHA="$(echo "$_pin_file" | grep '^SHA=' | cut -d= -f2)"
AGENT_PIN_DATE="$(echo "$_pin_file" | grep '^DATE=' | cut -d= -f2)"

if [[ -z "$AGENT_PIN_SHA" ]]; then
    echo "  ERROR: could not read librenms-agent.pin from repo"; exit 1
fi
echo "  librenms-agent pin: $AGENT_PIN_SHA ($AGENT_PIN_DATE)"

if [[ ! -d "$AGENT_DIR/.git" ]]; then
    # Shallow fetch of exact pinned commit — no full history needed
    mkdir -p "$AGENT_DIR"
    git -C "$AGENT_DIR" init -q
    git -C "$AGENT_DIR" remote add origin "$AGENT_REPO"
    git -C "$AGENT_DIR" fetch --depth=1 origin "$AGENT_PIN_SHA"
    git -C "$AGENT_DIR" checkout FETCH_HEAD
    echo "  OK: librenms-agent cloned at $AGENT_PIN_SHA"
else
    _current="$(git -C "$AGENT_DIR" rev-parse HEAD)"
    if [[ "$_current" != "$AGENT_PIN_SHA" ]]; then
        git -C "$AGENT_DIR" fetch --depth=1 origin "$AGENT_PIN_SHA"
        git -C "$AGENT_DIR" checkout FETCH_HEAD
        echo "  OK: librenms-agent updated to $AGENT_PIN_SHA"
    else
        echo "  SKIP: librenms-agent already at pinned commit"
    fi
fi

# ── check_mk agent binary ─────────────────────────────────────────────────────
# Always update — binary-only, no associated config to preserve
install -m 755 -o root -g root "$AGENT_DIR/check_mk_agent" /usr/bin/check_mk_agent
echo "  OK: check_mk_agent installed/updated"

# ── check_mk systemd socket service ──────────────────────────────────────────
mkdir -p /usr/lib/check_mk_agent/local /usr/lib/check_mk_agent/plugins
# Always update unit files alongside binary — idempotent
install -m 644 -o root -g root "$AGENT_DIR/check_mk.socket"   /etc/systemd/system/
install -m 644 -o root -g root "$AGENT_DIR/check_mk@.service" /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now check_mk.socket 2>/dev/null || systemctl start check_mk.socket
echo "  OK: check_mk socket service configured"

# ── SNMP extend scripts → /etc/snmp/ ─────────────────────────────────────────
# distro goes to /usr/bin/ (snmpd.conf references it there)
install -m 755 -o root -g root "$AGENT_DIR/snmp/distro" /usr/bin/distro

# Core extends — both modes
COMMON_EXTENDS="linux_softnet_stat chrony osupdate"

# PVE bare-metal extras (services always present on a PVE install)
PVE_EXTENDS="smart postfix-queues postfixdetailed zfs zfs-linux.py rrdcached"

# Extend scripts run as root but are readable by the snmp group for auditing
_all_extends="$COMMON_EXTENDS"
[[ "$MODE" == "pve" ]] && _all_extends="$_all_extends $PVE_EXTENDS"
_ext_ok=0
for _script in $_all_extends; do
    if [[ -f "$AGENT_DIR/snmp/$_script" ]]; then
        install -m 755 -o root -g Debian-snmp "$AGENT_DIR/snmp/$_script" "/etc/snmp/$_script"
        _ext_ok=$((_ext_ok + 1))
    else
        warn "extend script not found: $_script"
    fi
done
echo "  OK: $_ext_ok extend scripts installed"

# ── check_mk agent-local plugins ─────────────────────────────────────────────
PLUGIN_LIST_URL="$REPO_MODE/monitoring/checkmk-plugins"
_plugin_list="$(wget -qO- "$PLUGIN_LIST_URL" | grep -v '^#' | grep -v '^$' | awk '{print $1}')"
_plg_ok=0
for _plugin in $_plugin_list; do
    if [[ -f "$AGENT_DIR/agent-local/$_plugin" ]]; then
        install -m 755 -o root -g root "$AGENT_DIR/agent-local/$_plugin" \
            "/usr/lib/check_mk_agent/local/$_plugin"
        _plg_ok=$((_plg_ok + 1))
    fi
done
echo "  OK: $_plg_ok check_mk plugins installed"

# ── snmpd.conf ────────────────────────────────────────────────────────────────
if confirm_overwrite /etc/snmp/snmpd.conf "snmpd.conf" "$_pre_snmpd"; then
    wget -qO /tmp/snmpd.conf.new "$REPO_MODE/monitoring/snmpd.conf"
    sed -i \
        -e "s|SNMP_COMMUNITY|$SNMP_COMMUNITY|g" \
        -e "s|SYSLOCATION|$SYS_LOCATION|g" \
        -e "s|SYSCONTACT|$SYS_CONTACT|g" \
        /tmp/snmpd.conf.new
    # Validate: file must be non-empty and all placeholders substituted
    if [[ -s /tmp/snmpd.conf.new ]] \
        && grep -q "^com2sec" /tmp/snmpd.conf.new \
        && ! grep -qE 'SNMP_COMMUNITY|SYSLOCATION|SYSCONTACT' /tmp/snmpd.conf.new; then
        [[ -f /etc/snmp/snmpd.conf && ! -f /etc/snmp/snmpd.conf.orig ]] \
            && cp /etc/snmp/snmpd.conf /etc/snmp/snmpd.conf.orig
        mv /tmp/snmpd.conf.new /etc/snmp/snmpd.conf
        chown root:Debian-snmp /etc/snmp/snmpd.conf
        chmod 640 /etc/snmp/snmpd.conf
        if systemctl enable snmpd 2>/dev/null && systemctl restart snmpd 2>/dev/null; then
            echo "  OK: snmpd.conf applied and restarted (community: $SNMP_COMMUNITY)"
        else
            warn "snmpd failed to restart — check: journalctl -xeu snmpd"
        fi
    else
        rm -f /tmp/snmpd.conf.new
        echo "  WARNING: snmpd.conf validation failed — original kept"
        NEEDS_ATTENTION+=("Fix /etc/snmp/snmpd.conf — validation failed, original preserved")
    fi
fi

# ── smart.config (PVE only — auto-detect drives) ─────────────────────────────
if [[ "$MODE" == "pve" ]]; then
    SMART_CFG="/etc/snmp/smart.config"
    if [[ ! -f "$SMART_CFG" ]]; then
        wget -qO "$SMART_CFG" "$REPO_MODE/monitoring/smart.config"
        mkdir -p /var/cache/smart
        while IFS= read -r _dev; do
            _name="$(basename "$_dev")"
            if [[ "$_dev" == *nvme* ]]; then
                echo "$_name $_dev -d nvme" >> "$SMART_CFG"
            else
                echo "$_name $_dev -d sat" >> "$SMART_CFG"
            fi
        done < <(lsblk -dno NAME,TYPE /dev/sd* /dev/nvme* 2>/dev/null \
            | awk '$2=="disk"{print "/dev/"$1}')
        chown root:Debian-snmp "$SMART_CFG"
        chmod 640 "$SMART_CFG"
        echo "  OK: smart.config written with detected drives"
        NEEDS_ATTENTION+=("Verify auto-detected drive list in /etc/snmp/smart.config")
    fi
fi

# ── snmptrapd.conf (PVE only — Debian VMs don't receive traps) ───────────────
if [[ "$MODE" == "pve" ]]; then
    if confirm_overwrite /etc/snmp/snmptrapd.conf "snmptrapd.conf" "$_pre_snmptrapd"; then
        [[ -f /etc/snmp/snmptrapd.conf && ! -f /etc/snmp/snmptrapd.conf.orig ]] \
            && cp /etc/snmp/snmptrapd.conf /etc/snmp/snmptrapd.conf.orig
        wget -qO /tmp/snmptrapd.conf.new "$REPO_MODE/monitoring/snmptrapd.conf"
        sed -i "s|SNMP_COMMUNITY|$SNMP_COMMUNITY|g" /tmp/snmptrapd.conf.new
        mv /tmp/snmptrapd.conf.new /etc/snmp/snmptrapd.conf
        chown root:Debian-snmp /etc/snmp/snmptrapd.conf
        chmod 640 /etc/snmp/snmptrapd.conf
        if systemctl enable --now snmptrapd 2>/dev/null; then
            echo "  OK: snmptrapd.conf applied and service enabled"
        else
            warn "snmptrapd failed to start — check: journalctl -xeu snmptrapd"
        fi
    fi
fi

# ── collectd.conf ─────────────────────────────────────────────────────────────
if [[ -n "$COLLECTD_SERVER" && "$COLLECTD_SERVER" != "127.0.0.1" ]]; then
    if confirm_overwrite /etc/collectd/collectd.conf "collectd.conf" "$_pre_collectd"; then
        wget -qO /tmp/collectd.conf.new "$REPO_MODE/monitoring/collectd.conf"
        sed -i \
            -e "s|COLLECTD_HOSTNAME|$COLLECTD_HOSTNAME|g" \
            -e "s|COLLECTD_SERVER|$COLLECTD_SERVER|g" \
            /tmp/collectd.conf.new
        [[ -f /etc/collectd/collectd.conf && ! -f /etc/collectd/collectd.conf.orig ]] \
            && cp /etc/collectd/collectd.conf /etc/collectd/collectd.conf.orig
        mkdir -p /etc/collectd/collectd.conf.d
        mv /tmp/collectd.conf.new /etc/collectd/collectd.conf
        if systemctl enable collectd 2>/dev/null && systemctl restart collectd 2>/dev/null; then
            echo "  OK: collectd.conf applied and restarted (→ $COLLECTD_SERVER)"
        else
            warn "collectd failed to restart — check: journalctl -xeu collectd"
            NEEDS_ATTENTION+=("collectd failed to start — fix /etc/collectd/collectd.conf then: systemctl restart collectd")
        fi
    fi
else
    echo "  SKIP: collectd server not set — collectd.conf not deployed"
    NEEDS_ATTENTION+=("Configure collectd: edit /etc/collectd/collectd.conf with LibreNMS server IP")
fi

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
