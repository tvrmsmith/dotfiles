#!/bin/bash
# work-push-guard.sh — Claude Code PreToolUse (Bash) guard.
#
# Company policy on the work laptop: agents push code only to WellSky GitHub
# orgs. This denies a `git push`, `gh pr create`, `gh pr merge` or
# `gh repo create` whose target owner is outside them, and tells the agent to
# commit locally and stop. Trevor pushes by hand.
#
# Where it enforces: only when the org-managed Claude Code policy file exists.
# IT installs that file on work machines and a personal machine never has it,
# so the hook needs no per-machine setup and is a no-op at home.
# WORK_PUSH_GUARD_POLICY_FILES (colon-separated) overrides the paths for tests.
#
# How the target is found:
#   git push   the remote argument (a name or a URL), else the branch's push
#              remote, else origin; the repo is `git -C <dir>`, a leading
#              `cd <dir> &&`, or the session cwd.
#   gh pr      -R/--repo, else the owner in a PR URL argument, else origin.
#   gh repo create  the owner/name argument; a bare name lands on the user
#              account, which is not an allowed org.
# Anything it cannot resolve, and any non-GitHub host, gets "ask", not a guess,
# unless that host is listed in the machine-local trusted-hosts file: one host
# (or SSH alias) per line, # comments allowed. It lives outside this repo
# because the hosts are work values. WORK_PUSH_GUARD_TRUSTED_HOSTS_FILE
# overrides the path.
#
# Known gap: it sees only the agent's Bash tool calls. A push made inside a
# subprocess (no-mistakes, slice-pipeline, an orca worker's own session outside
# this machine's hooks) never passes through here. Splitting on && ; | is
# word-level, so quoting that hides an operator is not understood.

set -euo pipefail

ALLOWED_ORGS="bonafide-wsky careport clearcare healthify mediwareinc"
TRUSTED_HOSTS_FILE="${WORK_PUSH_GUARD_TRUSTED_HOSTS_FILE:-$HOME/.claude/work-push-guard.trusted-hosts}"
POLICY_FILES="${WORK_PUSH_GUARD_POLICY_FILES:-/Library/Application Support/ClaudeCode/managed-settings.json:/etc/claude-code/managed-settings.json}"

enforced=0
IFS=: read -ra files <<<"$POLICY_FILES"
for f in "${files[@]}"; do [ -f "$f" ] && enforced=1; done
[ "$enforced" = 1 ] || exit 0

command -v jq >/dev/null 2>&1 || exit 0
INPUT=$(cat)
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty')
[ -n "$CMD" ] || exit 0
[ -n "$CWD" ] || CWD=$PWD

# Cheap exit for the common case.
case "$CMD" in *git*push* | *gh*pr*create* | *gh*pr*merge* | *gh*repo*create*) ;; *) exit 0 ;; esac

emit() { # $1 decision, $2 reason
  jq -n --arg d "$1" --arg r "$2" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: $d, permissionDecisionReason: $r}}'
  exit 0
}

deny() {
  emit deny "Company policy on this machine: agents push only to WellSky GitHub orgs ($ALLOWED_ORGS). $1 is outside them. Commit locally and stop; Trevor pushes by hand."
}

allowed() { case " $ALLOWED_ORGS " in *" $1 "*) return 0 ;; esac; return 1; }

trusted_host() {
  [ -f "$TRUSTED_HOSTS_FILE" ] || return 1
  sed -e 's/#.*//' -e 's/[[:space:]]//g' "$TRUSTED_HOSTS_FILE" | grep -qxF -- "$1"
}

# Prints "<host> <owner>" for a git or GitHub URL, nothing if it is not one.
host_owner() {
  printf '%s\n' "$1" | sed -nE \
    -e 's#^[a-z+]+://([^@/]+@)?([^/:]+)(:[0-9]+)?/([^/]+)/.*#\2 \4#p' \
    -e 's#^([^@/]+@)?([^/:]+):([^/]+)/.*#\2 \3#p' | head -1
}

# Judges URL $1 (described as $2): returns on allowed, else emits.
judge_url() {
  local ho host owner
  ho=$(host_owner "$1")
  [ -n "$ho" ] || emit ask "Could not tell who owns $2 ($1). Push only to WellSky GitHub orgs."
  host=${ho% *} owner=${ho#* }
  trusted_host "$host" && return 0
  case "$host" in
    *github*) ;;
    *) emit ask "$2 is on $host, not GitHub. Agents push only to WellSky GitHub orgs; confirm this is allowed." ;;
  esac
  allowed "$owner" || deny "$2 ($owner)"
}

origin_url() { git -C "$1" remote get-url --push origin 2>/dev/null || true; }

check_git_push() { # $1 dir, rest: args after `push`
  local dir=$1 remote="" url
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      -o | --push-option | --receive-pack | --exec) shift ;;
      -*) ;;
      *) remote=$1; break ;;
    esac
    shift
  done
  if [ -z "$remote" ]; then
    remote=$(git -C "$dir" rev-parse --abbrev-ref '@{push}' 2>/dev/null | cut -d/ -f1 || true)
    [ -n "$remote" ] || remote=origin
  fi
  case "$remote" in
    *:* | */*) url=$remote ;;
    *) url=$(git -C "$dir" remote get-url --push "$remote" 2>/dev/null || true) ;;
  esac
  [ -n "$url" ] || emit ask "Could not resolve git remote '$remote' in $dir. Push only to WellSky GitHub orgs."
  judge_url "$url" "the push target '$remote'"
}

check_gh_pr() { # $1 dir, rest: args after `pr create|merge`
  local dir=$1 repo="" url=""
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      -R | --repo) repo=${2:-}; shift ;;
      --repo=*) repo=${1#--repo=} ;;
      https://*/pull/*) url=$1 ;;
    esac
    shift
  done
  if [ -n "$repo" ]; then
    owner=${repo%%/*}
    allowed "$owner" || deny "the PR repo $repo"
  elif [ -n "$url" ]; then
    judge_url "$url" "the PR $url"
  else
    url=$(origin_url "$dir")
    [ -n "$url" ] || emit ask "Could not tell which repo this gh pr command targets in $dir."
    judge_url "$url" "this repo's origin"
  fi
}

check_gh_repo_create() { # rest: args after `repo create`
  local name=""
  while [ $# -gt 0 ]; do
    case "$1" in -*) ;; *) name=$1; break ;; esac
    shift
  done
  case "$name" in
    */*) allowed "${name%%/*}" || deny "the new repo $name" ;;
    *) deny "a repo created on the user account (${name:-no name given})" ;;
  esac
}

# Walk each simple command. Word-level only; see the header.
dir=$CWD
segments=$(printf '%s\n' "$CMD" | sed -E 's/(&&|\|\||;|\|)/\n/g')
while IFS= read -r seg; do
  read -ra w <<<"$seg" || true
  [ ${#w[@]} -gt 0 ] || continue
  i=0
  while [ $i -lt ${#w[@]} ] && { [[ ${w[$i]} == *=* && ${w[$i]} != -* ]] || [ "${w[$i]}" = env ] || [ "${w[$i]}" = command ]; }; do
    i=$((i + 1))
  done
  [ $i -lt ${#w[@]} ] || continue
  prog=${w[$i]##*/}
  rest=("${w[@]:$((i + 1))}")
  case "$prog" in
    cd)
      target=${rest[0]:-$HOME}
      case "$target" in /*) dir=$target ;; *) dir="$dir/$target" ;; esac
      ;;
    git)
      gdir=$dir
      while [ ${#rest[@]} -gt 0 ]; do
        case "${rest[0]}" in
          -C) gdir=${rest[1]:-$gdir}; rest=("${rest[@]:2}") ;;
          -c) rest=("${rest[@]:2}") ;;
          -*) rest=("${rest[@]:1}") ;;
          *) break ;;
        esac
      done
      [ "${rest[0]:-}" = push ] && check_git_push "$gdir" "${rest[@]:1}"
      ;;
    gh)
      case "${rest[0]:-} ${rest[1]:-}" in
        "pr create" | "pr merge") check_gh_pr "$dir" "${rest[@]:2}" ;;
        "repo create") check_gh_repo_create "${rest[@]:2}" ;;
      esac
      ;;
  esac
done <<<"$segments"
exit 0
