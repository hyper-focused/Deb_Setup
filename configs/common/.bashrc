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
# High color when safe; don't clobber serial/console or already-good client TERM.
case "${TERM:-}" in
    ''|dumb|unknown|vt100|vt220)
        export TERM=xterm-256color
        ;;
    xterm)
        export TERM=xterm-256color
        ;;
    # linux (VC), screen*, tmux*, rxvt*, *-256color, etc. — leave as-is
esac
shopt -s checkwinsize   # update LINES/COLUMNS after each command (SSH clients)
# Immediate resize on SIGWINCH — critical for noVNC/HTML5 KVM consoles where
# the window can be resized without a new command being run. Silently no-ops if
# resize (xterm package) is not installed.
trap 'command -v resize &>/dev/null && eval "$(resize 2>/dev/null)"' SIGWINCH

# ── Debian chroot label ───────────────────────────────────────────────────────
if [ -z "$debian_chroot" ] && [ -r /etc/debian_chroot ]; then
    debian_chroot=$(cat /etc/debian_chroot)
fi

# ── Completions ───────────────────────────────────────────────────────────────
if [ -f /usr/share/bash-completion/bash_completion ]; then
    # shellcheck source=/dev/null
    . /usr/share/bash-completion/bash_completion
elif [ -f /etc/bash_completion ]; then
    # shellcheck source=/dev/null
    . /etc/bash_completion
fi

# ── Colors — ls, grep, less ───────────────────────────────────────────────────
export LS_COLORS="$(vivid generate snazzy 2>/dev/null || true)"
export LS_OPTIONS='--color=auto --group-directories-first'
alias ls='ls $LS_OPTIONS'
alias dir='dir --color=auto --group-directories-first'
alias vdir='vdir --color=auto --group-directories-first'
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
if command -v batcat &>/dev/null; then
    alias cat='batcat --color=auto'
elif command -v bat &>/dev/null; then
    alias cat='bat --color=auto'
fi

# bat-extras — extra names only (do not replace grep/diff; CLI differs)
command -v batgrep &>/dev/null && alias bgrep='batgrep'
command -v batdiff &>/dev/null && alias bdiff='batdiff'
command -v batman  &>/dev/null && alias bman='batman'

# ── fzf ───────────────────────────────────────────────────────────────────────
if command -v fzf &>/dev/null; then
    if [ -f /usr/share/doc/fzf/examples/key-bindings.bash ]; then
        # shellcheck source=/dev/null
        . /usr/share/doc/fzf/examples/key-bindings.bash
    fi
    if [ -f /usr/share/doc/fzf/examples/completion.bash ]; then
        # shellcheck source=/dev/null
        . /usr/share/doc/fzf/examples/completion.bash
    fi
fi

# ── zoxide ────────────────────────────────────────────────────────────────────
command -v zoxide &>/dev/null && eval "$(zoxide init bash)"

# ── pipx ──────────────────────────────────────────────────────────────────────
[ -d "$HOME/.local/bin" ] && PATH="$HOME/.local/bin:$PATH"

# ── NVM (PVE only — harmless if not installed) ────────────────────────────────
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ]          && . "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && . "$NVM_DIR/bash_completion"

# ── Direnv (harmless if not installed) ───────────────────────────────────────
command -v direnv &>/dev/null && eval "$(direnv hook bash)"

# ── Starship prompt ───────────────────────────────────────────────────────────
command -v starship &>/dev/null && eval "$(starship init bash)"
