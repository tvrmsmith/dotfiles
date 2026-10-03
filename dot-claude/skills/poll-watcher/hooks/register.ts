import type { EngineInterface, Register, Timer } from 'claude-code'
import { update } from 'claude-code'
import type { PollWatch } from '../types'

const WATCHES = { plugin: 'poll-watcher', key: 'watches' } as const
const STATUS_COMMANDS = ['no-mistakes axi status', 'gh pr checks', 'gh pr view', 'gh run view', 'gh run list']
const STATUS_COMMAND = new RegExp(`^(?:${STATUS_COMMANDS.join('|')})\\b`)
// The watcher re-runs the command, so it watches only a read-only status
// call. Once `2>&1` is set aside, anything that could chain, background,
// substitute or redirect leaves the command with the model, and a pipe may
// feed only filters that read and print. A flag that opens a browser tab or
// writes a file on every tick does the same.
const UNSAFE = /[&<;\n`>]|\$\(/
const FILTER = /^(?:head|tail|grep|jq|cut|sort|uniq|wc|cat)\b/
const SLEEP_THEN = /^\s*sleep\s+(\d+)([smh]?)\s*(?:;|&&)\s*(.+)$/s
const UNIT_MS: Record<string, number> = { '': 1000, s: 1000, m: 60_000, h: 3_600_000 }
const MIN_INTERVAL_MS = 15_000
const MAX_INTERVAL_MS = 600_000
const STOP_AFTER_MS = 3_600_000
const OUTPUT_LIMIT = 4000
const WATCH_LIMIT = 20
const STATUS_LIMIT = 120

// Tokens that move on every run without the status moving: ISO timestamps,
// clock times, "N minutes ago" and elapsed durations such as 1m23s.
const VOLATILE = [
  /\b\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?(?:Z|[+-]\d{2}:?\d{2})?/g,
  /\b\d{1,2}:\d{2}(?::\d{2})?\b/g,
  /\b(?:\d+|an?)\s+(?:second|minute|hour|day|week|month|year)s?\s+ago\b/g,
  /\b\d+(?:\.\d+)?(?:ms|[hms])(?:\d+(?:\.\d+)?(?:ms|[hms]))*\b/g,
]

type Poll = { command: string; intervalMs: number }

function writes(segment: string): boolean {
  const [name, ...args] = segment.trim().split(/\s+/)
  if (name === 'gh') return args.some(a => a === '-w' || a.startsWith('--web'))
  if (name === 'sort') return args.some(a => /^-[a-zA-Z]*o/.test(a) || a.startsWith('--output'))
  if (name === 'uniq') return args.filter(a => a === '-' || !a.startsWith('-')).length > 1
  return false
}

function isReadOnly(command: string): boolean {
  const segments = command.split('|')
  const [, ...filters] = segments
  return !UNSAFE.test(command) && filters.every(f => FILTER.test(f.trim())) && !segments.some(writes)
}

function parsePoll(text: string): Poll | undefined {
  const m = SLEEP_THEN.exec(text)
  if (!m) return undefined
  const [, n = '', unit = '', rest = ''] = m
  const command = rest.trim()
  if (!STATUS_COMMAND.test(command) || !isReadOnly(command.replaceAll('2>&1', ''))) return undefined
  const ms = Number(n) * (UNIT_MS[unit] ?? 1000)
  return { command, intervalMs: Math.min(MAX_INTERVAL_MS, Math.max(MIN_INTERVAL_MS, ms)) }
}

type Outcome = { output: string; masked: string; exitCode: number }

// Masked before the cut: a volatile token that changes length would otherwise
// move where the cut falls and read as a change.
function outcome(output: string, exitCode: number): Outcome {
  return { output: output.slice(-OUTPUT_LIMIT), masked: masked(output).slice(-OUTPUT_LIMIT), exitCode }
}

function note(command: string, intervalMs: number): string {
  return `poll-watcher dropped the sleep and ran \`${command}\` now. It re-runs the command every ${intervalMs / 1000} s and sends you a message when the output changes. Do not poll it again: end your turn or carry on with other work.`
}

// A TOON status nests its state under a parent key, so the `status:` line
// says more than the first one.
function statusLine(w: Pick<PollWatch, 'phase' | 'command' | 'output'>): string {
  const lines = w.output.split('\n').map(line => line.trim()).filter(line => line !== '')
  const shown = lines.find(line => line.startsWith('status:')) ?? lines[0] ?? ''
  return `${w.phase} · ${w.command} · ${shown}`.slice(0, STATUS_LIMIT)
}

async function run($: EngineInterface, command: string, cwd: string): Promise<Outcome> {
  const r = await $.process.run(['/bin/sh', '-c', command], { cwd })
  return outcome([r.stdout, r.stderr].filter(s => s !== '').join('\n').trim(), r.exitCode)
}

// The engine leads a refused call's rejection with the plugin and the call;
// the text around it already names both.
const REFUSAL_PREFIX = /^poll-watcher: \$\.process\.run: /

function messageOf(error: unknown): string {
  return (error instanceof Error ? error.message : String(error)).replace(REFUSAL_PREFIX, '')
}

// A run that rejects reads as output, so a command that starts failing is a
// change like any other.
async function runForTick($: EngineInterface, command: string, cwd: string): Promise<Outcome> {
  try {
    return await run($, command, cwd)
  } catch (error) {
    return outcome(`could not run: ${messageOf(error)}`, -1)
  }
}

// A Bash run the model never saw finish (interrupted, backgrounded, timed
// out) has no settled output to watch. An errored run's result is the stored
// error text rather than the tool's record, so read it as unknown.
function didNotFinish(result: unknown): boolean {
  if (typeof result !== 'object' || result === null) return false
  const r = result as { interrupted?: unknown; backgroundTaskId?: unknown; timedOutAfterMs?: unknown }
  return r.interrupted === true || r.backgroundTaskId !== undefined || r.timedOutAfterMs !== undefined
}

function sameKey(a: PollWatch, b: { command: string; cwd: string }): boolean {
  return a.command === b.command && a.cwd === b.cwd
}

// One pending tick per watch. Module state: a reload starts it empty and
// session.start re-arms from $.state.
const timers = new Map<string, Timer>()
// A subagent or a -p run has nobody to wake, so only an interactive main loop
// is watched. Set by session.start, which a reload fires again.
let isInteractive = false

function keyOf(w: { command: string; cwd: string }): string {
  return `${w.cwd}\n${w.command}`
}

function arm($: EngineInterface, w: PollWatch, delayMs = w.intervalMs): void {
  timers.get(keyOf(w))?.cancel()
  timers.set(keyOf(w), $.clock.after(delayMs, () => void tick($, w).catch(error => halt($, w, error))))
}

function isArmed(w: PollWatch, armed: PollWatch): boolean {
  return sameKey(w, armed) && w.armedAt === armed.armedAt
}

// A tick that failed armed nothing after it: show it stopped rather than
// leave it watching with no timer.
async function halt($: EngineInterface, armed: PollWatch, error: unknown): Promise<void> {
  $.ui.status(statusLine({ ...armed, phase: 'stopped', output: messageOf(error) }))
  await update($, WATCHES, list =>
    (list ?? []).map(w => (isArmed(w, armed) ? { ...w, phase: 'stopped' as const } : w)),
  ).catch(() => undefined)
}

// A reload drops the timers but keeps $.state: re-arm each watch still
// ticking (a changed one ticks on quietly), due where its last check left it;
// redraw the status entry.
async function resume($: EngineInterface): Promise<void> {
  const { value: list = [] } = await $.state.get(WATCHES)
  const now = await $.clock.now()
  for (const w of list) {
    if (w.phase !== 'stopped') arm($, w, Math.max(0, w.checkedAt + w.intervalMs - now))
  }
  const latest = list.reduce<PollWatch | undefined>((a, w) => (a && a.checkedAt >= w.checkedAt ? a : w), undefined)
  if (latest) $.ui.status(statusLine(latest))
}

function masked(output: string): string {
  return VOLATILE.reduce((text, pattern) => text.replace(pattern, '#'), output)
}

function changePrompt(w: PollWatch): string {
  return `poll-watcher: \`${w.command}\` changed. New output:\n\n${w.output}`
}

function stopPrompt(w: PollWatch): string {
  return `poll-watcher: \`${w.command}\` unchanged for 60 min, stopped watching. Last output:\n\n${w.output}`
}

type Checked = { watch: PollWatch; prompt?: string }

// One tick's outcome for the watch it ran: what to store, and what to tell a
// model still waiting on it. A stopped watch is not re-armed.
function check(w: PollWatch, result: Outcome, now: number): Checked {
  const isChanged = result.masked !== w.masked || result.exitCode !== w.exitCode
  const isWaiting = w.phase === 'watching'
  if (isChanged) {
    const watch: PollWatch = { ...w, ...result, phase: 'changed', checkedAt: now, changedAt: now }
    return { watch, prompt: isWaiting ? changePrompt(watch) : undefined }
  }
  const watch: PollWatch = { ...w, ...result, checkedAt: now }
  if (now - w.changedAt < STOP_AFTER_MS) return { watch }
  const stopped: PollWatch = { ...watch, phase: 'stopped' }
  return { watch: stopped, prompt: isWaiting ? stopPrompt(stopped) : undefined }
}

async function tick($: EngineInterface, armed: PollWatch): Promise<void> {
  const result = await runForTick($, armed.command, armed.cwd)
  const now = await $.clock.now()
  let checked: Checked | undefined
  await update($, WATCHES, list =>
    (list ?? []).map(w => {
      // A stale tick: the model re-polled since this one was armed.
      if (!isArmed(w, armed)) return w
      checked = check(w, result, now)
      return checked.watch
    }),
  )
  if (!checked) return
  const { watch, prompt } = checked
  $.ui.status(statusLine(watch))
  // Armed before the prompt: submit waits for the model's turn, and a re-poll
  // meanwhile arms a newer watch this one must not replace.
  if (watch.phase !== 'stopped') arm($, watch)
  // A refused prompt is dropped: state and the status entry already tell it.
  if (prompt) await $.prompt.submit({ text: prompt }).catch(() => undefined)
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    isInteractive = e.isInteractive
    const started = await next(e)
    await resume($)
    return started
  })

  on('tool.call', { tool: 'Bash' }, async ($, e, next) => {
    const isWatchable = isInteractive && e.agentId === undefined && e.run_in_background !== true
    const poll = isWatchable ? parsePoll(e.command) : undefined
    if (!poll) return next(e)

    const ran = await next({ ...e, command: poll.command })
    if (ran.deny !== undefined || didNotFinish(ran.result)) return ran
    const cwd = await $.session.cwd()
    // The baseline is a second run, not ran's stdout, so every compared value
    // comes from the same runner. One that cannot run arms nothing, and the
    // model is told so.
    let baseline: Outcome
    try {
      baseline = await run($, poll.command, cwd)
    } catch (error) {
      return { ...ran, context: [...(ran.context ?? []), `poll-watcher could not arm: ${messageOf(error)}`] }
    }
    const now = await $.clock.now()
    const watch: PollWatch = {
      command: poll.command,
      cwd,
      intervalMs: poll.intervalMs,
      phase: 'watching',
      ...baseline,
      armedAt: now,
      checkedAt: now,
      changedAt: now,
    }
    await update($, WATCHES, list =>
      [watch, ...(list ?? []).filter(w => !sameKey(w, watch))].slice(0, WATCH_LIMIT),
    )
    $.ui.status(statusLine(watch))
    arm($, watch)

    return { ...ran, context: [...(ran.context ?? []), note(poll.command, poll.intervalMs)] }
  })
}
