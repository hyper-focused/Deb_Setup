# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A single-script post-install setup for **Proxmox VE 9** (bare metal) and **Debian 13** (QEMU VM). Run as root via:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/hyper-focused/Deb_Setup/main/init.sh)
```

The script prompts for OS mode (`pve` or `debian`) then fully configures packages, dotfiles, monitoring, and SSH.

## Linting / validation

```bash
shellcheck init.sh                        # lint the main script
shfmt -i 4 -l init.sh                    # check formatting (4-space indent)
shfmt -i 4 -w init.sh                    # auto-format in place
bash -n init.sh                          # syntax check only
```

There is no automated test suite. Validate config files by deploying to a VM and checking service status (`systemctl status snmpd`, `sshd -t`, etc.).

## Architecture

### Entry point

`init.sh` is the only executable. It is fully self-contained and sourced from GitHub at deploy time. It:
1. Selects mode (`MODE=pve` or `MODE=debian`) via interactive prompt
2. Installs packages (common + mode-specific)
3. Downloads config files from this repo via `wget` into their final system paths
4. Applies template substitution (see below)
5. Enables/restarts services

### Config layout

```
configs/
  common/          # Deployed to both modes
    .bashrc
    .gitconfig
    .tmux.conf
    .vimrc
    starship.toml
    bat/config
    htop/htoprc
    btop/btop.conf
  pve/             # Proxmox VE (bare metal) only
    sshd_config
    sysctl.conf
    zramswap
    monitoring/
      snmpd.conf
      snmptrapd.conf
      collectd.conf
      smart.config       # skeleton; init.sh appends auto-detected drives
      checkmk-plugins    # list of agent-local plugin names to install
  debian/          # Debian 13 QEMU VM only
    sshd_config
    sysctl.conf
    monitoring/
      snmpd.conf
      collectd.conf
      checkmk-plugins
```

The variable `$REPO_COMMON` points to `configs/common` and `$REPO_MODE` points to `configs/pve` or `configs/debian`.

### Template substitution pattern

Config files use ALL_CAPS placeholders that `init.sh` replaces with `sed -i` before deploying:

| Placeholder | Value source |
|---|---|
| `SNMP_COMMUNITY` | Interactive prompt |
| `SYSLOCATION` | Interactive prompt |
| `SYSCONTACT` | Interactive prompt |
| `COLLECTD_HOSTNAME` | `hostname -f` |
| `COLLECTD_SERVER` | Interactive prompt |
| `RSYSLOG_SERVER` | Interactive prompt |
| `RSYSLOG_SEVERITY` | Interactive prompt (debug/info/notice/warning/err/crit) |

After substitution, `init.sh` validates the result (non-empty, no remaining placeholders) before moving to the system path.

### Monitoring stack

All hosts ship two monitoring paths:
- **SNMP** via `snmpd` — LibreNMS polls this; extend scripts come from `librenms/librenms-agent` at the SHA pinned in `librenms-agent.pin`
- **check_mk** via socket service — LibreNMS pulls agent-local plugins listed in `configs/<mode>/monitoring/checkmk-plugins`

PVE hosts additionally run `collectd` (push to LibreNMS server UDP 25826) and `snmptrapd`.

### librenms-agent pinning

`librenms-agent.pin` contains `SHA=` and `DATE=` for the exact commit of `librenms/librenms-agent` to clone. Update this file (not init.sh) when upgrading the agent. The init script fetches only that commit (`--depth=1 fetch <sha>`).

### SSH ports

- Port **22**: kept open on PVE for cluster traffic; must be restricted at external firewall
- Port **2211**: key-only admin access (both modes); fail2ban must be configured for this port

### confirm_overwrite pattern

Service config deployments call `confirm_overwrite dst label pre` before downloading:

- **File absent** → proceed silently (first run, no existing config to protect)
- **`pre=false`** (package was just installed by this script) → proceed silently (config is still at distro default)
- **`pre=true`** (package was already installed before the script ran) → prompt `[y/N]`

Pre-install state is captured into `_pre_*` booleans (via `dpkg -l`) at script start, before any `apt-get install`. Packages tracked: `openssh-server`, `snmpd`, `snmptrapd`, `collectd`, `zram-tools`.

When adding a new config deployment, follow this pattern:
```bash
_pre_foo=false; _pkg_installed foo && _pre_foo=true   # near top with other _pre_* lines
...
if confirm_overwrite /etc/foo/foo.conf "foo.conf" "$_pre_foo"; then
    # download, substitute, validate, move
fi
```

For files with no owning package (e.g. `/etc/sysctl.d/99-init.conf`), omit the third argument — `confirm_overwrite` defaults to prompting whenever the file exists.

### Conventions

- `set -euo pipefail` throughout; all errors exit via the `ERR` trap
- Prefer `if/then/else` over `A && B || C` (shellcheck SC2015)
- Non-fatal failures go to `FAILURES[]` via `warn()`; post-install action items go to `NEEDS_ATTENTION[]`
- `DEBIAN_FRONTEND=noninteractive` on all `apt-get` calls
- Originals are preserved as `.orig` before overwriting system files (`sshd_config.orig`, `snmpd.conf.orig`, etc.)
- bat is installed as `batcat` on Debian/Ubuntu; `.bashrc` checks both names
