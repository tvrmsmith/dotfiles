### Added by Zinit's installer
if [[ ! -f $HOME/.local/share/zinit/zinit.git/zinit.zsh ]]; then
    print -P "%F{33} %F{220}Installing %F{33}ZDHARMA-CONTINUUM%F{220} Initiative Plugin Manager (%F{33}zdharma-continuum/zinit%F{220})…%f"
    command mkdir -p "$HOME/.local/share/zinit" && command chmod g-rwX "$HOME/.local/share/zinit"
    command git clone https://github.com/zdharma-continuum/zinit "$HOME/.local/share/zinit/zinit.git" && \
        print -P "%F{33} %F{34}Installation successful.%f%b" || \
        print -P "%F{160} The clone has failed.%f%b"
fi

source "$HOME/.local/share/zinit/zinit.git/zinit.zsh"
autoload -Uz _zinit
(( ${+_comps} )) && _comps[zinit]=_zinit

# Load a few important annexes, without Turbo
# (this is currently required for annexes)
zinit light-mode for \
    zdharma-continuum/zinit-annex-as-monitor \
    zdharma-continuum/zinit-annex-bin-gem-node \
    zdharma-continuum/zinit-annex-patch-dl \
    zdharma-continuum/zinit-annex-rust

zinit ice as"command" from"gh-r" \
          atclone"./starship init zsh > init.zsh; ./starship completions zsh > _starship" \
          atpull"%atclone" src"init.zsh"
zinit light starship/starship

zinit ice wait lucid
zinit snippet OMZP::gcloud

### End of Zinit's installer chunk
autoload -Uz compinit
compinit
autoload -U bashcompinit && bashcompinit

eval "$(mise activate zsh)" # this sets up interactive sessions

source /Users/trevor.smith/dev/wellsky/consolo.docker-dev/.helpers/compose.sh
source /Users/trevor.smith/dev/wellsky/consolo.docker-dev/.helpers/git.sh
source /Users/trevor.smith/dev/wellsky/consolo.docker-dev/.helpers/system.sh
source <(just --completions bash)

if command -v zoxide > /dev/null; then
  eval "$(zoxide init zsh --cmd d)"
fi

[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"  # This loads nvm
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"  # This loads nvm bash_completion
# Source the Lazyman shell initialization for aliases and nvims selector
# shellcheck source=.config/nvim-Lazyman/.lazymanrc
[ -f ~/.config/nvim-Lazyman/.lazymanrc ] && source ~/.config/nvim-Lazyman/.lazymanrc
# Source the Lazyman .nvimsbind for nvims key binding
# shellcheck source=.config/nvim-Lazyman/.nvimsbind
[ -f ~/.config/nvim-Lazyman/.nvimsbind ] && source ~/.config/nvim-Lazyman/.nvimsbind

alias ghcr-docker-login="op run --no-masking -- printenv GIT_TOKEN | docker login ghcr.io -u "$GIT_USER" --password-stdin"
alias gauth="gcloud auth application-default login"

alias bundle='BUNDLE_RUBYGEMS__PKG__GITHUB__COM="$GIT_USER:$(op read $GIT_TOKEN)" bundle'
alias logdy='logdy --no-analytics --port=8090'
alias just='op run -- just'
alias docker='op run -- docker'
alias ls='lsd --group-dirs first -l'
