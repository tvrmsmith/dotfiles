# mysbx interactive launchers. Sourced via init.zsh from .zshrc.
# The executable (~/.local/bin/mysbx) is the non-interactive entry point; these
# functions add the all-in-one create-if-needed convenience for interactive use.
source "${0:A:h}/lib/mysbx-core.zsh"
_mysbx_load_config
# Resolve eagerly only when sbx is reachable (or REAL_SBX is configured); never
# abort sourcing on a machine without sbx — the functions resolve lazily at call
# time and fail loudly there instead of breaking every interactive shell.
{ [[ -n "${REAL_SBX:-}" ]] || command -v sbx >/dev/null 2>&1; } && _mysbx_resolve_real_sbx

mysbx-cc()      { _mysbx_launch cc "$@"; }
mysbx-ruby-cc() { _mysbx_launch ruby-cc "$@"; }
mysbx-omp()     { _mysbx_launch omp "$@"; }

mysbx-build()     { _mysbx_build "$@"; }
mysbx-omp-build() { _mysbx_omp_build "$@"; }
mysbx-omp-clean() { _mysbx_omp_clean "$@"; }
mysbx-update()    { _mysbx_update "$@"; }
mysbx-check()     { _mysbx_check "$@"; }
