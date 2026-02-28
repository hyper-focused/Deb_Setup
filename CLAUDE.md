# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A single-script post-install setup for **Proxmox VE 9** (bare metal) and **Debian 13** (QEMU VM). Run as root via:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/hyper-focused/Deb_Setup/main/init.sh)
```

The script prompts for OS mode (`pve` or `debian`) then fully configures packages, dotfiles, SSH, rsyslog remote forwarding, sysctl tuning, and a full monitoring stack (SNMP + check_mk + collectd).

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
  common/                  # Deployed to both modes
    .bashrc
    .gitconfig
    .tmux.conf
    .vimrc
    starship.toml
    bat/config
    htop/htoprc
    btop/btop.conf
    rsyslog-remote.conf    # Template for /etc/rsyslog.d/99-remote.conf
  pve/                     # Proxmox VE (bare metal) only
    sshd_config
    sysctl.conf
    zramswap
    monitoring/
      snmpd.conf
      collectd.conf
      smart.config         # Skeleton; init.sh appends auto-detected drives
      checkmk-plugins      # List of agent-local plugin names to install
      temperature          # Curated check_mk plugin (upstream is incomplete template)
  debian/                  # Debian 13 QEMU VM only
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
- **SNMP** via `snmpd` — LibreNMS polls this; extend scripts sourced from `librenms/librenms-agent` at the SHA pinned in `librenms-agent.pin`
- **check_mk** via socket service — LibreNMS pulls agent-local plugins listed in `configs/<mode>/monitoring/checkmk-plugins`

PVE hosts additionally run `collectd` (push to LibreNMS server UDP 25826).

#### Extend scripts — hybrid sourcing

Scripts in `COMMON_EXTENDS` and `PVE_EXTENDS` are installed from the librenms-agent clone. Key notes:
- `entropy.sh` is the upstream filename; the install loop strips `.sh` so the destination is `/etc/snmp/entropy` (matching `snmpd.conf` extend directives). All other scripts have no extension.
- `rrdcached` exists only in `agent-local/`, not `snmp/` — it is a check_mk plugin, not an SNMP extend.

#### check_mk plugins — hybrid sourcing

Most plugins install from the librenms-agent clone. Exceptions hosted in this repo:
- **`temperature`** (`configs/pve/monitoring/temperature`) — upstream plugin is an incomplete `hddtemp` template. Our version uses `sensors -j` (lm-sensors) and outputs per-sensor warn/crit thresholds in check_mk local format.

#### librenms-agent pinning

`librenms-agent.pin` contains `SHA=` and `DATE=` for the exact commit of `librenms/librenms-agent` to clone. Update this file (not `init.sh`) when upgrading the agent. The init script fetches only that commit (`--depth=1 fetch <sha>`).

### SSH ports

- Port **22**: kept open on PVE for cluster traffic; must be restricted at external firewall
- Port **2211**: key-only admin access (both modes); fail2ban must be configured for this port

### confirm_overwrite pattern

Service config deployments use `confirm_overwrite dst label pre` to avoid silently clobbering custom configs:

- **File absent** → proceed silently (first run, nothing to protect)
- **`pre=false`** (package just installed by this script) → proceed silently (still at distro default)
- **`pre=true`** (package was already installed before this script ran) → prompt `[y/N]`

Pre-install state is captured into `_pre_*` booleans (via `dpkg -l`) at script start, before any `apt-get install`. Packages tracked: `openssh-server`, `rsyslog`, `snmpd`, `collectd`, `zram-tools`.

**Prompt ordering rule**: overwrite checks always run *before* parameter prompts. In the monitoring step, both `confirm_overwrite` calls happen at the top of the step; SNMP and collectd parameter prompts are skipped entirely if the corresponding configs won't be deployed.

**rsyslog special case**: when the drop-in (`/etc/rsyslog.d/99-remote.conf`) is absent but rsyslog is pre-installed, an explicit opt-in prompt ("configure remote forwarding? [y/N]") is shown before asking for server IP and severity. This is because the drop-in is a new addition, not an overwrite.

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
