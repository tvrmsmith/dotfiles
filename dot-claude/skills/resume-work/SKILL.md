---
name: resume-work
description: Find every session that stalled while Trevor was away and start it again. `/resume-work` to sweep and restart, `/resume-work status` for the board alone.
disable-model-invocation: true
---

# Resume work

Trevor has been away and a couple of dozen sessions have been sitting. Checking each one by hand is
the problem this solves. Nothing has to be armed before he leaves: every session's state is already
in its own terminal scrollback, and this reads it.

Trevor typed `/resume-work` just now. Sweep, print the board, then branch on the argument:

| argument | do |
| --- | --- |
| nothing | send, below |
| `status`, `board`, `who` | stop at the board, send nothing |

## Sweep

`~/.claude/docs/terminal-fanout.md` picks the targets and holds the typing mechanics. This reads
them first. Write the script to a temp file and run it, since a heredoc and a pipe both claim stdin:

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
reports itself as a long hung turn. And it matches error strings in the last 12 lines only, since a
session that has been *discussing* `API Error` otherwise reads as one that suffered it.

Read the tail of anything whose `recap` came back empty and take its last assistant paragraph
instead; a session too young or too freshly cleared to have a recap still says what it is doing.

## Bucket

Four buckets, first match wins, every session in exactly one.

| bucket | evidence | send |
| --- | --- | --- |
| `WORKING` | `turn` is set | nothing, it is mid-turn |
| `ERRORED` | `error` is set | the resume line |
| `DECIDE` | the recap or tail ends on a question, an approval, or an `Enter to select` dialog | nothing, it wants Trevor |
| `GO` | stopped clean, recap names a next step | the resume line |
| `DONE` | stopped clean, recap says nothing is pending | nothing |

`turn` is the elapsed clock off the session's own spinner line (`✳ Undulating… (43m 24s · …)`),
which is the honest measure of how long the current turn has run. `idle_min` only separates
sitting-at-a-prompt from alive, since a working session emits nothing for minutes at a stretch.

A long `turn` is usually honest work. Every one measured so far was a deliberate `sleep 560` CI
wait, so report `turn` and `call` and let Trevor read the anomaly himself rather than guessing at a
hang.

## Send

`GO` and `ERRORED` both just need their turn started again, and both hold full context in a process
the outage never killed. Type this at each, per `~/.claude/docs/terminal-fanout.md`:

```text
Trevor is back at the keyboard. Pick up where you left off and carry on.
```

An `ERRORED` session lost its turn to a failed API call, which happens between tool calls rather
than inside one, so its files are consistent and the same line is all it needs.

## Report

One row per session, `DECIDE` first, since those are the only ones Trevor has to act on:

```text
BUCKET  | turn   | title                          | what it is waiting on
DECIDE  | -      | Approval of prior work         | discard emr-be6mp.7 or rewrite it down to the header remnant
DECIDE  | -      | Hospice epic emr-as2n5         | unlock the 1Password vault so four bead close-outs can push
GO      | -      | no-mistakes-archon gap review  | sent, next is comparing extractor output against the Go run
WORKING | 29m 7s | restart.exempt_paths           | sleep 560, waiting on a CI rerun
DONE    | -      | Custom lint rules beads status | merged, pushed, bead closed
```

Spell out each `DECIDE` question in full under the board, since answering them is the actual work
left. Close with the count per bucket and the sessions Orca does not manage, which this never
reached.
