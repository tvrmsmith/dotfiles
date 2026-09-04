# The sweep

Every live Claude session on this machine, bucketed by what it is waiting on. Reached from
`SKILL.md` by `/park`, `/park back`, and `/park status`. Runs with no network: Orca is local IPC and
the evidence is already sitting in each terminal's scrollback.

## Gather

`~/.claude/docs/terminal-fanout.md` picks the targets; this reads them. One pass over every target,
extracting four signals per session:

Write it to a temp file and run it, since a heredoc and a pipe both claim stdin:

```python
import json, os, subprocess, re, time

def orca(*args):
    r = subprocess.run(['orca', *args], capture_output=True, text=True)
    return json.loads(r.stdout)['result']

ERR = re.compile(r'API Error|fetch failed|Connection error|reach the API server'
                 r'|session expired|agent refused operation|Permission denied \(publickey\)'
                 r'|error: 1Password:')
SPIN = re.compile(r'\w+…\s*\((?:(\d+)m\s*)?(\d+)s\b')
CALL = re.compile(r'^\s*(?:⏺\s*|(?:⎿\s*)?\$\s*)(?!Tip:)(.+)')

me = orca('terminal', 'show', '--terminal', os.environ['ORCA_TERMINAL_HANDLE'], '--json')['terminal']
now, seen = time.time() * 1000, {me['tabId']}
for t in orca('terminal', 'list', '--json')['terminals']:
    if not (t.get('connected') and not t.get('orphaned') and t.get('agentIdentity') == 'claude'):
        continue
    if t['tabId'] in seen or not t.get('lastOutputAt'):
        continue
    seen.add(t['tabId'])
    try:
        tail = orca('terminal', 'read', '--terminal', t['handle'],
                    '--limit', '80', '--json')['terminal']['tail']
    except Exception:
        continue
    lines = [l.strip() for l in tail if l.strip()]
    spin = next((m for l in lines for m in [SPIN.search(l)] if m), None)
    recap = next((re.sub(r'\s+', ' ', l) for l in reversed(lines) if 'recap:' in l), '')
    err = ';'.join(sorted({m.group(0) for l in lines[-12:] for m in [ERR.search(l)] if m})) or '-'
    call = next((re.sub(r'\s+', ' ', m.group(1))[:70]
                 for l in reversed(lines) for m in [CALL.match(l)] if m), '')
    print(json.dumps({
        'handle': t['handle'], 'title': t.get('title', '')[:40],
        'cwd': t.get('worktreePath', ''), 'idle_min': int((now - t['lastOutputAt']) / 60000),
        'turn': f"{int(spin.group(1) or 0)}m{spin.group(2)}s" if spin else '-',
        'error': err, 'call': call, 'recap': recap[:220]}))
```

Two narrowings in there are load-bearing, both learned by running it. It drops its own tab, or it
reports itself as a 40-minute hung turn. And it matches error strings in the last 12 lines only,
since a session that has been *discussing* `API Error` reads as a session that suffered one, while a
real error that killed the turn is always at the bottom.

Read the tail of anything whose `recap` came back empty, and take its last assistant paragraph
instead; a session too young or too freshly cleared to have a recap still says what it is doing.

## Bucket

Six buckets, first match wins. Fill every session into exactly one, and name the evidence.

| bucket | evidence | meaning |
| --- | --- | --- |
| `STUCK` | `turn` past ~10m, and `call` is `op`, `git push`, `gh`, or a fetch | hung on a 1Password prompt or a dead network, not on work |
| `WORKING` | `turn` set, and `call` is work that is honestly slow | genuinely running, leave it |
| `ERRORED` | `error` set | the outage killed the turn; context survives in the process |
| `DECIDE` | the recap or the tail ends on a question, an approval, or a `Enter to select` dialog | waiting on Trevor |
| `GO` | stopped clean, and the recap names a next step | one line restarts it |
| `DONE` | stopped clean, and the recap says nothing is pending | finished |

`turn` is the elapsed clock off the session's own spinner line (`✳ Undulating… (43m 24s · …)`),
which is the honest measure of how long the current turn has run. `idle_min` only separates
sitting-at-a-prompt from alive: a genuinely working session emits nothing for minutes at a stretch,
so idle time alone flags healthy sessions as hung.

The `STUCK` line between hung and slow is a judgment call `call` settles, and the clock alone gets
it wrong in both directions. A session 29 minutes into `sleep 560; cat ...` is waiting on a CI
rerun on purpose. A session two minutes into `op read op://...` is already dead, because the
biometric prompt it is waiting on has nobody to answer it. Put `call` in the report and let Trevor
overrule the call.

## Report

One row per session, `STUCK` and `DECIDE` first, since those are the only two Trevor has to act on:

```text
BUCKET  | turn   | title                          | what it is waiting on
STUCK   | 22m14s | Hospice seed contributor       | op read op://Private/... , biometric prompt unanswered
DECIDE  | -      | Approval of prior work         | discard emr-be6mp.7 or rewrite it down to the header remnant
GO      | -      | no-mistakes-archon gap review  | next is comparing extractor output against the Go run
DONE    | -      | Custom lint rules beads status | merged, pushed, bead closed
```

Close with the count per bucket and the sessions Orca does not manage, which this never reached.
