" ── Basic settings ───────────────────────────────────────────────────────────
set nocompatible
syntax on
filetype plugin indent on

set number          " line numbers
set relativenumber  " relative line numbers
set cursorline      " highlight current line
set showmatch       " highlight matching brackets
set incsearch       " incremental search
set hlsearch        " highlight search results
set ignorecase      " case-insensitive search...
set smartcase       "   unless uppercase used

" ── Indentation ───────────────────────────────────────────────────────────────
set tabstop=4
set shiftwidth=4
set expandtab
set autoindent
set smartindent

" ── UI ────────────────────────────────────────────────────────────────────────
set ruler
set wildmenu
set laststatus=2
set scrolloff=8
set sidescrolloff=8
set wrap
set linebreak

" ── Files ─────────────────────────────────────────────────────────────────────
set encoding=utf-8
set noswapfile
set nobackup
set autoread

" ── Colors ────────────────────────────────────────────────────────────────────
set termguicolors
set background=dark

" ── Key maps ──────────────────────────────────────────────────────────────────
let mapleader = " "
nnoremap <leader>h :nohlsearch<CR>
nnoremap <leader>w :w<CR>
nnoremap <leader>q :q<CR>

" Move between splits with Ctrl+hjkl
nnoremap <C-h> <C-w>h
nnoremap <C-j> <C-w>j
nnoremap <C-k> <C-w>k
nnoremap <C-l> <C-w>l
