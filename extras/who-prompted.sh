#!/usr/bin/env bash
#
# Name the process behind a 1Password approval prompt.
#
# The prompt says which application is asking but never which command, so a GUI
# app polling in the background looks exactly like an agent doing real work. A
# blocked process is a live process: whatever triggered the prompt sits waiting
# for the approval, for seconds, so a one-second sampler is certain to catch it.
#
#   extras/who-prompted.sh &      # start before reproducing
#   tail -f ~/.local/state/op-prompt-watch.log
#
# Ctrl-C to stop. Writes nothing until something matches.
set -uo pipefail

LOG="${XDG_STATE_HOME:-$HOME/.local/state}/op-prompt-watch.log"
mkdir -p "$(dirname "$LOG")"

# The three things that reach 1Password: the CLI (biometric), the ssh agent via
# a git or ssh invocation (key approval), and the retired signing helper.
WATCH='(^|/)(op|ssh|git-remote-http|op-ssh-sign)( |$)|op plugin run|ssh -|git (push|fetch|pull|ls-remote)'

# Walk pid -> ppid so the log names the app, not just the leaf process.
ancestry() {
	local pid="$1" out="" line
	for _ in 1 2 3 4 5 6; do
		line=$(ps -o ppid=,comm= -p "$pid" 2>/dev/null) || break
		[ -n "$line" ] || break
		out="$out < ${line#* }"
		pid=${line%% *}
		pid=${pid# }
		[ -z "$pid" ] || [ "$pid" -le 1 ] 2>/dev/null && break
	done
	printf '%s' "$out"
}

printf '%s  watching for processes that reach 1Password\n' "$(date '+%Y-%m-%d %H:%M:%S')" >> "$LOG"
seen=""
while :; do
	while IFS= read -r row; do
		pid=${row%% *}
		args=${row#* }
		case " $seen " in *" $pid "*) continue ;; esac
		printf '%s  pid=%-7s %s\n%*sancestry:%s\n' \
			"$(date '+%Y-%m-%d %H:%M:%S')" "$pid" "${args:0:160}" 22 "" "$(ancestry "$pid")" >> "$LOG"
		seen="$seen $pid"
	done < <(ps -axo pid=,args= 2>/dev/null | grep -vE 'who-prompted|grep ' | grep -E "$WATCH" || true)
	# Forget pids older than the last few hundred so a long run stays bounded.
	seen=$(printf '%s' "$seen" | tr ' ' '\n' | tail -300 | tr '\n' ' ')
	sleep 1
done
