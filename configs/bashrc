# ~/.bashrc — hyper-focused/Deb_Setup
# Executed by bash(1) for non-login shells.

# If not running interactively, don't do anything
[ -z "$PS1" ] && return

# ── History ───────────────────────────────────────────────────────────────────
HISTCONTROL=ignoredups:ignorespace
shopt -s histappend
HISTSIZE=5000
HISTFILESIZE=10000

# ── Terminal ──────────────────────────────────────────────────────────────────
export TERM=xterm-256color
shopt -s checkwinsize

# ── Debian chroot label ───────────────────────────────────────────────────────
if [ -z "$debian_chroot" ] && [ -r /etc/debian_chroot ]; then
    debian_chroot=$(cat /etc/debian_chroot)
fi

# ── Colors — ls, grep, less ───────────────────────────────────────────────────
export LS_COLORS="$(vivid generate molokai 2>/dev/null || true)"
export LS_OPTIONS='--color=auto --group-directories-first'
alias ls='ls $LS_OPTIONS'
alias dir='dir --color=auto'
alias vdir='vdir --color=auto'
alias grep='grep --color=auto'
alias fgrep='fgrep --color=auto'
alias egrep='egrep --color=auto'

export LESS="-R"
export LESS_TERMCAP_mb=$'\e[1;38;2;249;38;114m'
export LESS_TERMCAP_md=$'\e[0;38;2;102;217;239m'
export LESS_TERMCAP_me=$'\e[0m'
export LESS_TERMCAP_se=$'\e[0m'
export LESS_TERMCAP_so=$'\e[0;38;2;226;209;57m'
export LESS_TERMCAP_ue=$'\e[0m'
export LESS_TERMCAP_us=$'\e[0;38;2;0;255;135m'

# ── Editor ────────────────────────────────────────────────────────────────────
export EDITOR=nano
export VISUAL=nano

# ── bat aliases ───────────────────────────────────────────────────────────────
if command -v bat &>/dev/null; then
    alias cat='bat --color=auto'
elif command -v batcat &>/dev/null; then
    alias cat='batcat --color=auto'
fi

# ── bat-extras ────────────────────────────────────────────────────────────────
command -v batgrep &>/dev/null && alias grep='batgrep'
command -v batdiff &>/dev/null && alias diff='batdiff'
command -v batman  &>/dev/null && alias man='batman'

# ── NVM (PVE only — harmless if not installed) ────────────────────────────────
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ]          && . "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && . "$NVM_DIR/bash_completion"

# ── Direnv (harmless if not installed) ───────────────────────────────────────
command -v direnv &>/dev/null && eval "$(direnv hook bash)"

# ── Starship prompt ───────────────────────────────────────────────────────────
command -v starship &>/dev/null && eval "$(starship init bash)"
