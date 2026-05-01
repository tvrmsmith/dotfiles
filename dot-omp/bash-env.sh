# Sourced by every non-interactive bash spawned by OMP's bash tool, via the
# BASH_ENV variable exported in dot-zshenv. Defines wrappers that strip
# CI from tools that mis-detect a CI environment and refuse useful work
# (e.g. sherif --fix bails out with "Cannot fix issues inside a CI environment").
#
# OMP injects CI=1 unconditionally via NON_INTERACTIVE_ENV in pi-coding-agent's
# bash-executor.ts, with no env-var override. Inline shell wrappers are the
# only deterministic fix that doesn't require patching the package.
#
# Scope guard: BASH_ENV is global to all non-interactive bash spawned from
# our zsh sessions. Only register wrappers when invoked under OMP — detected
# via OMPCODE=1, which pi-utils/procmgr.ts unconditionally injects into every
# OMP-spawned shell env. Outside OMP this file is a no-op.

[ "$OMPCODE" = "1" ] || return 0

bunx() {
	if [ "$1" = "sherif" ]; then
		shift
		env -u CI bunx sherif "$@"
	else
		command bunx "$@"
	fi
}