#!/usr/bin/env python3
"""Measure how long agent runs actually get, and how much ADC demand they create.

    ./extras/measure-agent-runs.py            # everything still on disk
    ./extras/measure-agent-runs.py 2026-08-07 # only from that date

Written for the remote-agent-host beads (dotfiles-bri.5, dotfiles-bri.14), whose whole
question is whether unattended runs outlast the credentials and the laptop. Both had to be
answered from measurement rather than impression, and both need re-answering whenever the
workflow changes, so the method lives here instead of in a scratch file.

Two things make the numbers mean something:

Wall-clock session span is useless. A resumed session spans days while idle, so it measures
retention, not work. The two measures below both cut at a 30-minute silence instead.

Local transcript retention is about a month. Re-run this before comparing against a figure
recorded on a bead: the window the earlier figure covered may no longer be on disk, and the
right move is then to compare against what the bead recorded, having first checked this
script still reproduces the overlap.
"""

import glob
import json
import os
import re
import sys
from datetime import datetime, timezone

PROJECTS = os.path.expanduser('~/.claude/projects')
GCLOUD_LOGS = os.path.expanduser('~/.config/gcloud/logs')

# The silence that ends an active burst, and that stops idle time counting toward a stretch.
GAP_SECONDS = 30 * 60


def parse_timestamp(record):
    raw = record.get('timestamp')
    if not raw:
        return None
    try:
        return datetime.fromisoformat(raw.replace('Z', '+00:00'))
    except ValueError:
        return None


def is_human_turn(record):
    """A turn the human actually typed.

    Everything the harness feeds back looks like a user record: tool results, system
    reminders, the echo of a slash command, the caveat prepended to a resumed session. Any
    of those counted as a human turn would cut an unattended stretch in half and hide
    exactly the long runs this is measuring.
    """
    if record.get('type') != 'user' or record.get('isMeta'):
        return False

    content = (record.get('message') or {}).get('content')
    if isinstance(content, list):
        if any(isinstance(b, dict) and b.get('type') == 'tool_result' for b in content):
            return False
        text = ' '.join(b.get('text', '') for b in content if isinstance(b, dict))
    else:
        text = content or ''

    text = text.lstrip()
    if not text.strip():
        return False
    return not text.startswith(('<system-reminder>', '<local-command', 'Caveat:'))


def session_events(path, since):
    """Every timestamped event in one transcript, as `(when, was_typed_by_a_human)`."""
    events = []
    try:
        with open(path, encoding='utf-8', errors='replace') as handle:
            for line in handle:
                line = line.strip()
                if not line:
                    continue
                try:
                    record = json.loads(line)
                except json.JSONDecodeError:
                    continue
                when = parse_timestamp(record)
                if when is not None and when >= since:
                    events.append((when, is_human_turn(record)))
    except OSError:
        return []
    events.sort(key=lambda event: event[0])
    return events


def active_bursts(events):
    """Contiguous work, split wherever the session goes quiet for longer than the gap."""
    spans = []
    start = previous = events[0][0]
    for when, _ in events[1:]:
        if (when - previous).total_seconds() > GAP_SECONDS:
            spans.append((previous - start).total_seconds())
            start = when
        previous = when
    spans.append((previous - start).total_seconds())
    return spans


def unattended_stretches(events):
    """Dense time between one human turn and the next: how long the agent ran alone.

    Only event-dense time counts, so a session left open overnight does not read as an
    all-night agent run.
    """
    spans = []
    anchored = False
    dense = 0.0
    previous = None
    for when, human in events:
        if anchored and previous is not None and (when - previous).total_seconds() <= GAP_SECONDS:
            dense += (when - previous).total_seconds()
        if human:
            if anchored:
                spans.append(dense)
            anchored, dense = True, 0.0
        previous = when
    if anchored:
        spans.append(dense)
    return spans


def percentile(values, p):
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, round(p / 100 * (len(ordered) - 1)))]


def duration(seconds):
    return f'{seconds / 60:.1f}m' if seconds < 3600 else f'{seconds / 3600:.1f}h'


def report(name, values, thresholds):
    if not values:
        print(f'\n{name}: nothing in window')
        return
    print(f'\n{name}: n={len(values)}, {sum(values) / 3600:.0f}h total')
    print('  ' + ' | '.join(f'p{p}' for p in (50, 75, 90, 95, 99)) + ' | max')
    print(
        '  '
        + ' | '.join(duration(percentile(values, p)) for p in (50, 75, 90, 95, 99))
        + f' | {duration(max(values))}'
    )
    print('  ' + ', '.join(f'>{duration(t)}: {sum(1 for v in values if v > t)}' for t in thresholds))


def adc_demand(since):
    """Application Default Credentials traffic, one gcloud log file per invocation.

    The count that matters is `application-default print-access-token`, the non-interactive
    fetch. `application-default login` is the interactive repair, so it counts humans
    interrupted rather than demand.
    """
    day_pattern = re.compile(r'^(\d{4})\.(\d{2})\.(\d{2})$')
    rows = []
    for entry in sorted(os.listdir(GCLOUD_LOGS)) if os.path.isdir(GCLOUD_LOGS) else []:
        match = day_pattern.match(entry)
        if not match:
            continue
        day = datetime(*(int(g) for g in match.groups()), tzinfo=timezone.utc)
        if day < since:
            continue
        fetches = logins = failures = total = 0
        for log in glob.glob(os.path.join(GCLOUD_LOGS, entry, '*')):
            try:
                with open(log, encoding='utf-8', errors='replace') as handle:
                    body = handle.read()
            except OSError:
                continue
            total += 1
            if 'Running [gcloud.auth.application-default.print-access-token]' in body:
                fetches += 1
            if 'Running [gcloud.auth.application-default.login]' in body:
                logins += 1
            if 'Reauthentication failed' in body:
                failures += 1
        rows.append((entry, total, fetches, logins, failures))
    return rows


def main():
    since = (
        datetime.fromisoformat(sys.argv[1]).replace(tzinfo=timezone.utc)
        if len(sys.argv) > 1
        else datetime(1970, 1, 1, tzinfo=timezone.utc)
    )

    # Subagent and sidechain transcripts are turns inside a parent session, not sessions.
    transcripts = [
        path
        for path in glob.glob(os.path.join(PROJECTS, '**', '*.jsonl'), recursive=True)
        if not {'subagents', 'sidechains'} & set(path.split(os.sep))
    ]

    bursts, stretches, sessions = [], [], 0
    earliest = latest = None
    for path in transcripts:
        events = session_events(path, since)
        if not events:
            continue
        sessions += 1
        earliest = min(earliest or events[0][0], events[0][0])
        latest = max(latest or events[-1][0], events[-1][0])
        bursts += active_bursts(events)
        stretches += unattended_stretches(events)

    if not sessions:
        print(f'no transcript events since {since:%Y-%m-%d}')
        return

    days = (latest - earliest).days + 1
    print(f'{earliest:%Y-%m-%d} to {latest:%Y-%m-%d} ({days} days), {sessions} top-level sessions')
    report('active bursts', bursts, [1800, 3600, 7200, 14400, 21600, 28800])
    report('unattended stretches', stretches, [600, 1200, 1800, 3600, 7200, 14400])
    print('  ten longest: ' + ', '.join(f'{v / 60:.0f}m' for v in sorted(stretches, reverse=True)[:10]))

    rows = adc_demand(since)
    print('\nADC demand, one gcloud log file per invocation')
    if not rows:
        print('  no gcloud activity in window')
        return
    print(f'  {"day":<12} {"gcloud":>7} {"adc-fetch":>10} {"adc-login":>10} {"reauth-fail":>12}')
    for day, total, fetches, logins, failures in rows:
        print(f'  {day:<12} {total:>7} {fetches:>10} {logins:>10} {failures:>12}')
    print(
        f'  {"total":<12} {sum(r[1] for r in rows):>7} {sum(r[2] for r in rows):>10}'
        f' {sum(r[3] for r in rows):>10} {sum(r[4] for r in rows):>12}'
    )


if __name__ == '__main__':
    main()
