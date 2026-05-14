# Agent sandboxing init — source from .zshrc
_AGENT_SBX_ROOT="${0:A:h}"
for _f in "$_AGENT_SBX_ROOT"/*.zsh; do
  [[ "${_f:t}" == init.zsh ]] && continue
  source "$_f"
done; unset _f
