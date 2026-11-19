#!/usr/bin/env bash
# A/B harness for implement-with-subagents: split (one worker per assignment)
# against single (one worker for the whole slice). The skill calls it twice per
# run, `assign` first and `finish` last; `report` reads the result.
#
#   ab.sh assign <slice-id> [--unattended]
#     Hashes the slice id to an arm, appends a start row, prints
#     {"run","arm","assigned"}. An empty slice id (a free-text slice) is
#     unassigned: it runs split and the report leaves it out.
#   ab.sh finish --run <id> --status ready --branch B --sha S --killed K
#   ab.sh finish --run <id> --status aborted
#     Both take [--redos N] [--fanin-failures N] [--models JSON] [--forced]
#     [--fit-fallback] [--note TEXT]. K is mutants killed out of 5. Appends the
#     metrics row. Arm, wall-clock and tokens come from the start row and the
#     session transcripts, the coding-standards arm from that experiment's log,
#     never from the caller. Prints a notice once both arms reach STOP_AT.
#   ab.sh report
#     Per-arm summary of every counted slice in this experiment.
#
# The arm is a pure function of EXPERIMENT and the slice id, so a resumed or
# rerun slice stays in its arm. Changing EXPERIMENT starts a fresh experiment.
set -euo pipefail

EXPERIMENT=iws-ab-v1
DIR="${IWS_AB_DIR:-$HOME/.claude/implement-with-subagents}"
STARTS="$DIR/starts.jsonl"
METRICS="$DIR/metrics.jsonl"
PROJECTS="${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"
NM_DB="${NM_STATE_DB:-$HOME/.no-mistakes/state.sqlite}"
# The coding-standards experiment's per-session arm log, written by the
# skill-arm.sh hook. Recorded per run so the two experiments can be read apart.
CS_ARMS="${XDG_STATE_HOME:-$HOME/.local/state}/coding-standards/arms.jsonl"
SESSION="${CLAUDE_CODE_SESSION_ID:-}"
# The stopping rule's sample size per arm; EXPERIMENT.md defers to this value.
STOP_AT="${IWS_AB_STOP_AT:-20}"

# The rows the experiment counts: assigned, unforced, and only the newest row
# per slice, so a rerun slice is one sample, not two.
# shellcheck disable=SC2016  # jq program, not shell expansion
COUNTED='def counted($e): map(select(.experiment == $e and .arm != "unassigned"
    and (.forced | not))) | group_by([.slice, .repo]) | map(max_by(.end));'

die() { printf 'ab.sh: %s\n' "$*" >&2; exit 2; }
warn() { printf 'ab.sh: warning: %s\n' "$*" >&2; }
now_iso() { date -u +%Y-%m-%dT%H:%M:%S.000Z; }

sha1_of() {
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 1
  else
    printf '%s' "$1" | sha1sum
  fi
}

# A failed or empty hash stays unassigned rather than logging a fake arm.
arm_for() {
  [ -n "$1" ] || { echo unassigned; return; }
  case "$(sha1_of "$EXPERIMENT#$1" 2>/dev/null || true)" in
    [0-7]*) echo split ;;
    [89a-f]*) echo single ;;
    *) echo unassigned ;;
  esac
}

cs_arm() {
  [ -n "$SESSION" ] && [ -f "$CS_ARMS" ] || return 0
  jq -rR --arg s "$SESSION" 'fromjson? | select(.session_id == $s) | .arm' "$CS_ARMS" | tail -n 1
}

cmd_assign() {
  local slice="${1-}" unattended=false
  [ "${2-}" = --unattended ] && unattended=true
  local arm assigned=true run_arm ts
  arm="$(arm_for "$slice")"
  run_arm="$arm"
  if [ "$arm" = unassigned ]; then assigned=false; run_arm="split"; fi
  ts="$(now_iso)"
  local run="${slice:-adhoc}@$ts"
  local repo="" repo_path=""
  repo_path="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  repo="$(git config --get remote.origin.url 2>/dev/null || true)"
  [ -n "$SESSION" ] || warn "CLAUDE_CODE_SESSION_ID is unset, so finish cannot read this run's token usage"
  mkdir -p "$DIR"
  jq -cn --arg e "$EXPERIMENT" --arg run "$run" --arg ts "$ts" --arg slice "$slice" \
    --arg arm "$arm" --arg s "$SESSION" --arg repo "$repo" --arg rp "$repo_path" \
    --arg cs "$(cs_arm)" --argjson u "$unattended" \
    '{experiment:$e, run:$run, ts:$ts, slice:$slice, arm:$arm, session_id:$s,
      repo:$repo, repo_path:$rp, cs_arm:(if $cs == "" then null else $cs end),
      unattended:$u}' >>"$STARTS"
  jq -cn --arg run "$run" --arg arm "$run_arm" --argjson a "$assigned" \
    '{run:$run, arm:$arm, assigned:$a}'
}

# Transcript files for session $1: the parent log and every subagent log.
transcripts() {
  [ -n "$1" ] && [ -d "$PROJECTS" ] || return 0
  find "$PROJECTS" -mindepth 2 -maxdepth 2 -name "$1.jsonl" 2>/dev/null
  find "$PROJECTS" -mindepth 4 -maxdepth 4 -path "*/$1/subagents/*.jsonl" 2>/dev/null
}

# Sums usage since ISO time $1 across sessions $2...; each message counted once.
tokens_since() {
  local since="$1"; shift
  local files=() f s
  for s in "$@"; do
    while IFS= read -r f; do [ -n "$f" ] && files+=("$f"); done < <(transcripts "$s")
  done
  if [ ${#files[@]} -eq 0 ]; then echo null; return; fi
  jq -cR --arg since "$since" 'fromjson? | select(.message.usage? and (.timestamp // "") >= $since)
      | {id: .message.id, u: .message.usage}' "${files[@]}" |
    jq -cs 'unique_by(.id) | map(.u) | {
      input: (map(.input_tokens // 0) | add // 0),
      output: (map(.output_tokens // 0) | add // 0),
      cache_read: (map(.cache_read_input_tokens // 0) | add // 0),
      cache_write: (map(.cache_creation_input_tokens // 0) | add // 0)}'
}

is_count() { case "$1" in '' | *[!0-9]*) return 1 ;; esac; }

cmd_finish() {
  local run="" status="" branch="" sha="" killed="" redos=0 fanin=0 models=null
  local forced=false fit=false note=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --run) run="$2"; shift 2 ;;
      --status) status="$2"; shift 2 ;;
      --branch) branch="$2"; shift 2 ;;
      --sha) sha="$2"; shift 2 ;;
      --killed) killed="$2"; shift 2 ;;
      --redos) redos="$2"; shift 2 ;;
      --fanin-failures) fanin="$2"; shift 2 ;;
      --models) models="$2"; shift 2 ;;
      --forced) forced=true; shift ;;
      --fit-fallback) fit=true; shift ;;
      --note) note="$2"; shift 2 ;;
      *) die "finish: unknown flag $1" ;;
    esac
  done
  case "$status" in
    ready)
      [ -n "$branch" ] && [ -n "$sha" ] && [ -n "$killed" ] ||
        die "finish: a ready run needs --branch, --sha and --killed"
      case "$killed" in [0-5]) ;; *) die "finish: --killed must be 0 to 5, got '$killed'" ;; esac
      ;;
    aborted)
      [ -z "$branch$sha$killed" ] || die "finish: an aborted run takes no --branch, --sha or --killed"
      ;;
    *) die "finish: --status must be ready or aborted" ;;
  esac
  is_count "$redos" || die "finish: --redos must be a whole number, got '$redos'"
  is_count "$fanin" || die "finish: --fanin-failures must be a whole number, got '$fanin'"
  jq -e 'type == "object" or . == null' <<<"$models" >/dev/null 2>&1 ||
    die "finish: --models must be a JSON object, got '$models'"
  [ -f "$STARTS" ] || die "finish: no start rows in $STARTS"
  local start
  start="$(jq -cR --arg r "$run" 'fromjson? | select(.run == $r)' "$STARTS" | tail -n 1)"
  [ -n "$start" ] || die "finish: no start row for run $run"
  if $fit && [ "$(jq -r .arm <<<"$start")" != single ]; then
    die "finish: --fit-fallback applies only to a single-arm run"
  fi
  local since s0 tokens end wall
  since="$(jq -r .ts <<<"$start")"
  s0="$(jq -r .session_id <<<"$start")"
  # A resumed run can finish under a new session id, so tokens span both.
  local sessions=("$s0")
  [ -n "$SESSION" ] && [ "$SESSION" != "$s0" ] && sessions+=("$SESSION")
  tokens="$(tokens_since "$since" "${sessions[@]}")"
  [ "$tokens" != null ] || warn "no transcripts found under $PROJECTS for session ${sessions[*]:-(none)}; tokens recorded as null"
  end="$(now_iso)"
  wall="$(jq -rn --arg a "$since" --arg b "$end" \
    '(($b | sub("\\.\\d+Z$"; "Z") | fromdate) - ($a | sub("\\.\\d+Z$"; "Z") | fromdate))')"
  jq -cn --argjson start "$start" --arg status "$status" --arg branch "$branch" --arg sha "$sha" \
    --arg killed "$killed" --argjson redos "$redos" --argjson fanin "$fanin" \
    --argjson models "$models" --argjson tokens "$tokens" --argjson wall "$wall" \
    --arg end "$end" --argjson forced "$forced" --argjson fit "$fit" --arg note "$note" \
    'def opt($s): if $s == "" then null else $s end;
     $start + {end:$end, status:$status, wall_s:$wall, tokens:$tokens,
      branch:opt($branch), sha:opt($sha),
      mutation_kill_rate:(if $killed == "" then null else ($killed | tonumber) / 5 end),
      redos:$redos, fanin_failures:$fanin, models:$models,
      forced:$forced, fit_fallback:$fit}
     + (if $note == "" then {} else {note:$note} end)' >>"$METRICS"
  stopping_notice
}

stopping_notice() {
  if jq -Rs --arg e "$EXPERIMENT" --argjson n "$STOP_AT" "$COUNTED"'
      [split("\n")[] | fromjson?] | counted($e) | map(select(.status == "ready"))
      | group_by(.arm) | map(select(length >= $n)) | length == 2' "$METRICS" | grep -q true; then
    echo "ab.sh: $EXPERIMENT stopping point reached: both arms hold $STOP_AT ready slices. Run ab.sh report and apply the stopping rule in ~/.claude/skills/implement-with-subagents/EXPERIMENT.md."
  fi
}

# Every no-mistakes pipeline run with its count of error and warning findings
# from the first review and test rounds. A fixed query; rows are matched to
# slices in jq. Prints [] when the database is absent, and warns as well when
# the query fails, so a broken query cannot pass for a repo without no-mistakes.
nm_runs() {
  [ -f "$NM_DB" ] || { echo '[]'; return; }
  local out err
  err="$(mktemp)"
  if ! out="$(sqlite3 -readonly -json "file:$NM_DB?mode=ro" "
    SELECT runs.branch, repos.upstream_url AS repo, repos.working_path AS repo_path,
           runs.created_at,
           (SELECT COUNT(*) FROM step_results sr
              JOIN step_rounds rd ON rd.step_result_id = sr.id AND rd.round = 1,
              json_each(rd.findings_json, '\$.findings') f
            WHERE sr.run_id = runs.id AND sr.step_name IN ('review', 'test')
              AND json_extract(f.value, '\$.severity') IN ('error', 'warning')) AS escaped
    FROM runs JOIN repos ON repos.id = runs.repo_id;" 2>"$err")"; then
    warn "no-mistakes query failed, so escaped findings read as null: $(cat "$err")"
    out='[]'
  fi
  rm -f "$err"
  printf '%s' "${out:-[]}"
}

cmd_report() {
  [ -f "$METRICS" ] || die "report: no metrics at $METRICS"
  local nm
  nm="$(nm_runs)"
  jq -Rrs --arg e "$EXPERIMENT" --argjson nm "$nm" "$COUNTED"'
    def epoch: sub("\\.\\d+Z$"; "Z") | fromdate;
    # The earliest pipeline run on the slice repo and branch after it finished.
    def escaped_for($r):
      if $r.branch == null then null else
        [$nm[] | select(.branch == $r.branch
            and (.repo == $r.repo or .repo_path == $r.repo_path)
            and .created_at >= ($r.end | epoch))]
        | sort_by(.created_at) | first | .escaped? // null end;
    def mean: if length == 0 then null else (add / length * 100 | round / 100) end;
    def median: if length == 0 then null else sort | .[length / 2 | floor] end;
    # Effective tokens: cache reads bill at about a tenth of input, cache writes near par.
    def eff: .input + .output + .cache_write + (.cache_read / 10);
    [split("\n")[] | fromjson?] | counted($e) | map(. + {escaped: escaped_for(.)}) |
    "experiment \($e)",
    (group_by(.arm)[] | . as $g | ($g | map(select(.status == "ready"))) as $ok |
      "\($g[0].arm): runs \($g | length), ready \($ok | length), aborted \($g | map(select(.status == "aborted")) | length)",
      "  mutation kill rate, mean:   \($ok | map(.mutation_kill_rate | select(. != null)) | mean)",
      "  escaped findings, mean:     \($ok | map(.escaped | select(. != null)) | mean) over \($ok | map(select(.escaped != null)) | length) runs",
      "  effective tokens, median:   \($g | map(.tokens | select(. != null) | eff) | median)",
      "  wall minutes, median:       \($g | map(select(.unattended)) | map(.wall_s / 60 | round) | median) unattended, \($g | map(select(.unattended | not)) | map(.wall_s / 60 | round) | median) attended",
      "  redos, mean:                \($g | map(.redos) | mean)",
      "  fan-in failures, mean:      \($g | map(.fanin_failures) | mean)",
      "  fit fallbacks:              \($g | map(select(.fit_fallback)) | length)",
      "  by repo:                    \($g | group_by(.repo) | map("\(.[0].repo | split("/") | last | sub("\\.git$"; "")) \(length)") | join(", "))")' "$METRICS"
}

case "${1-}" in
  assign) shift; cmd_assign "$@" ;;
  finish) shift; cmd_finish "$@" ;;
  report) shift; cmd_report "$@" ;;
  *) die "usage: ab.sh assign|finish|report" ;;
esac
