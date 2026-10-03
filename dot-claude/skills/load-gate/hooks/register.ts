// load-gate: holds a Bash test run while the machine is short of memory or CPU.
//
// Many agents share this machine, and a test suite started while it is short of
// memory or CPU runs slower, times out, and slows every other session down with
// it. Before a test-runner command this samples two signals, and holds the call
// while either is low:
//
//   memory  `memory_pressure` free percentage below 20
//   CPU     idle percentage from `top` below 10
//
// The load average is deliberately not a signal. macOS counts threads blocked on
// I/O in it, so under swap it read 134 on 14 cores while the CPU sat 37% idle,
// and a gate keyed on it held every test run all day.
//
// A held call waits on a host child (`sh` polling for a flag file) that a timer
// releases by writing the flag. A `tool.call` hook has a 10 s budget of its own
// time: a `$.clock` wait or a plain promise counts against it, a `$.process.run`
// in flight does not. Held calls queue in arrival order, and every 30 s a tick
// resamples and, once the machine is free, releases the oldest alone, so queued
// suites start one per tick and each re-reads the load the last one added.
//
// The wait is capped at 590 s (the child's own 600 s timeout, the most
// `$.process.run` allows, is the backstop), after which the command runs anyway:
// a caller's own timeout keeps counting while the hook holds, so an unbounded
// wait turns a slow run into a timed-out one.
//
// The hook never denies a test run (only an interrupt while held ends one). It
// only delays, so the normal permission flow still decides whether the command
// runs. A signal it cannot read counts as healthy, so a missing tool never holds
// anything.
//
// no-mistakes runs its unit test commands in its daemon, not through an agent,
// so this does not gate the pipeline's test step.

import type { EngineInterface, Register, Timer } from 'claude-code'
import { type Load, describeLoad, isBusy, parseFreeMemory, parseIdleCpu } from './load'
import { isTestRun } from './test-run'

const TICK_MS = 30_000
const CAP_MS = 590_000
const CHILD_TIMEOUT_MS = 600_000
const MEMORY_ARGV = ['memory_pressure']
const CPU_ARGV = ['top', '-l', '2', '-n', '0', '-s', '1']
// The child polls once a second, so a release reaches the call within 1 s.
const HOLD_SCRIPT = 'while [ ! -e "$1" ]; do sleep 1; done; rm -f "$1"'
const FLAG_DIR = '/tmp/claude-load-gate'

// The calls a tick or a timer makes on a held entry's behalf, through that
// entry's own `$`: its dispatch stays alive while it waits, where the one that
// started the tick may have finished. The engine refuses `$` stored in an
// object, so each entry carries closures over its `$` instead.
type Host = {
  sample: () => Promise<Load>
  now: () => Promise<number>
  status: (text: string | undefined) => void
  write: (path: string) => Promise<void>
  log: (text: string) => void
}

// Why an entry left the queue.
type Outcome = 'freed' | 'capped' | 'aborted'

type Release = { outcome: Outcome; at: number; load: Load }

type Entry = {
  host: Host
  flag: string
  heldAt: number
  heldLoad: Load
  cap?: Timer
  released?: Promise<Release>
}

const queue: Entry[] = []
let latest: Load = { memory: undefined, cpu: undefined }
let tick: Timer | undefined
let isSampling = false

// A run that fails reads as no output, which parses as an unreadable signal.
const stdoutOf = async ($: EngineInterface, argv: readonly string[]): Promise<string> => {
  try {
    return (await $.process.run(argv)).stdout
  } catch {
    return ''
  }
}

const sampleLoad = async ($: EngineInterface): Promise<Load> => {
  const [memory, cpu] = await Promise.all([stdoutOf($, MEMORY_ARGV), stdoutOf($, CPU_ARGV)])
  latest = { memory: parseFreeMemory(memory), cpu: parseIdleCpu(cpu) }
  return latest
}

const showStatus = (host: Host) => {
  host.status(queue.length > 0 ? `load-gate: ${queue.length} held (${describeLoad(latest)})` : undefined)
}

// Everything up to the first await runs at once, so the entry is out of the
// queue before anything else can see it.
const leave = async (entry: Entry, outcome: Outcome): Promise<Release> => {
  const load = latest
  entry.cap?.cancel()
  queue.splice(queue.indexOf(entry), 1)
  if (queue.length === 0) {
    tick?.cancel()
    tick = undefined
  }
  showStatus(entry.host)
  const at = await entry.host.now()
  try {
    await entry.host.write(entry.flag)
  } catch (error) {
    // The entry is gone from the queue either way; its child ends at its own timeout.
    entry.host.log(`load-gate: could not write ${entry.flag} to release a held test run: ${String(error)}`)
  }
  return { outcome, at, load }
}

// The one way out of the queue, for tick, cap, abort and a failed hold child
// alike; a later call for the same entry answers the first release.
const release = (entry: Entry, outcome: Outcome): Promise<Release> => (entry.released ??= leave(entry, outcome))

const onTick = async () => {
  const head = queue[0]
  if (!head || isSampling) return
  isSampling = true
  try {
    const load = await head.host.sample()
    const current = queue[0]
    if (!current) return
    if (isBusy(load)) showStatus(current.host)
    else await release(current, 'freed')
  } catch (error) {
    head.host.log(`load-gate: tick failed: ${String(error)}`)
  } finally {
    isSampling = false
  }
}

const outcomeLine = (entry: Entry, { outcome, at, load }: Release) => {
  const seconds = Math.round((at - entry.heldAt) / 1000)
  const change = `was ${describeLoad(entry.heldLoad)}, now ${describeLoad(load)}`
  return outcome === 'freed'
    ? `load-gate: held the tests ${seconds}s until the machine freed up (${change}).`
    : `load-gate: machine stayed busy for ${seconds}s (${change}); running the tests anyway, so expect them to be slow.`
}

export const register: Register = on => {
  on('tool.call', { tool: 'Bash' }, async ($, e, next) => {
    if (!isTestRun(e.command)) return next(e)
    const load = await sampleLoad($)
    // A run never jumps the queue, whatever its own sample says.
    if (queue.length === 0 && !isBusy(load)) return next(e)

    const entry: Entry = {
      host: {
        sample: () => sampleLoad($),
        now: () => $.clock.now(),
        status: text => $.ui.status(text),
        write: path => $.fs.write(path, ''),
        log: text => $.ui.log(text, { to: 'debug' }),
      },
      flag: `${FLAG_DIR}/${crypto.randomUUID()}`,
      heldAt: await $.clock.now(),
      heldLoad: load,
    }
    queue.push(entry)
    showStatus(entry.host)
    entry.cap = $.clock.after(CAP_MS, () => void release(entry, 'capped'))
    tick ??= $.clock.every(TICK_MS, () => void onTick())

    const onAbort = () => void release(entry, 'aborted')
    next.signal.addEventListener('abort', onAbort, { once: true })
    if (next.signal.aborted) onAbort()
    try {
      await $.process.run(['sh', '-c', HOLD_SCRIPT, 'sh', entry.flag], { timeoutMs: CHILD_TIMEOUT_MS })
    } catch (error) {
      // Timed out or never started: the release below counts it as the cap.
      entry.host.log(`load-gate: hold child for ${entry.flag} failed: ${String(error)}`)
    } finally {
      next.signal.removeEventListener('abort', onAbort)
    }
    // A child that exited without a release (killed, or the catch above) ran out of hold.
    const released = await release(entry, 'capped')
    if (released.outcome === 'aborted') return { deny: 'load-gate: interrupted while the tests were held.' }

    const ran = await next(e)
    if (ran.deny !== undefined) return ran
    const line = outcomeLine(entry, released)
    $.ui.toast(line)
    return { ...ran, context: [...(ran.context ?? []), line] }
  })
}
