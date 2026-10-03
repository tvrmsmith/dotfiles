import type { On } from 'claude-code'
import type { Engine, Plugin } from 'claude-code/testing'
import { expect, mock, test } from 'claude-code/testing'
import type { PollWatch } from '../types'

// The test's `$` carries no `state` noun, and a test hook's `$.state.get` is
// refused (the test file is not scanned), so an inline plugin reads the
// watches with `$.state.get` and answers them through a slash command.
const PROBE: Plugin = {
  name: 'probe',
  register(on) {
    on('command.run', { command: 'watches' }, async $ => {
      const { value } = await $.state.get({ plugin: 'poll-watcher', key: 'watches' })
      return { text: JSON.stringify(value ?? null) }
    })
  },
}
const WITH_PROBE = { plugins: [PROBE] }

async function watches($: Engine): Promise<PollWatch[] | null> {
  const { text } = await $.command.run({
    command: 'watches',
    args: '',
    origin: { kind: 'composer' },
    presentation: { isFullscreen: false, columns: 80 },
  })
  return JSON.parse(text ?? 'null')
}

// The subagent pass-through (`e.agentId` set) has no test: `$.tool.call`
// drops `agentId`, so a test cannot raise a subagent's Bash call.

const T0 = 1_000_000
const ST = 'no-mistakes axi status'
const POLL = `sleep 240; ${ST}`
const CWD = '/work/repo'
const START = { cwd: CWD, surface: 'terminal', isInteractive: true } as const

type BashAnswer = { deny: string } | { result: { stdout: string; stderr: string; interrupted: boolean } }

// The engine beneath the plugin: Bash, process.run, prompt.submit and
// ui.status answered from variables each test changes.
function world(on: On) {
  const clock = mock.clock(on, { now: T0 })
  const w = {
    clock,
    output: 'run: running',
    runError: undefined as Error | undefined,
    bashAnswer: undefined as BashAnswer | undefined,
    bashCommands: [] as string[],
    runs: [] as { argv: readonly string[]; cwd: string | undefined }[],
    prompts: [] as string[],
    status: undefined as string | undefined,
  }
  on('session.start', (_$, e) => ({ cwd: e.cwd }))
  on('session.cwd', () => ({ value: CWD }))
  on('tool.call', { tool: 'Bash' }, (_$, e) => {
    w.bashCommands.push(e.command)
    return w.bashAnswer ?? { result: { stdout: w.output, stderr: '', interrupted: false } }
  })
  on('process.run', (_$, e) => {
    w.runs.push({ argv: e.argv, cwd: e.init?.cwd })
    // A test hook that throws is skipped, not rethrown; a deny is how the
    // bottom makes the plugin's $.process.run reject.
    if (w.runError) return { deny: w.runError.message }
    return {
      value: { exitCode: 0, stdout: w.output, stderr: '', isStdoutTruncated: false, isStderrTruncated: false },
    }
  })
  on('prompt.submit', (_$, e) => {
    w.prompts.push(e.text)
    return { text: e.text }
  })
  on('ui.status', (_$, e) => {
    w.status = e.text
    return { value: undefined }
  })
  return w
}

async function armed($: Engine, on: On) {
  const w = world(on)
  await $.session.start(START)
  await $.tool.call({ tool: 'Bash', command: POLL })
  return w
}

async function changedOnce($: Engine, on: On) {
  const w = await armed($, on)
  w.output = 'run: passed'
  await w.clock.advance(240_000)
  return w
}

async function watchOne($: Engine): Promise<PollWatch> {
  const [first] = (await watches($)) ?? []
  if (!first) throw new Error('no watch in state')
  return first
}

test('drops the sleep, never blocks', WITH_PROBE, async ($, on) => {
  const w = world(on)
  await $.session.start(START)

  const ran = await $.tool.call({ tool: 'Bash', command: POLL })

  expect(w.clock.now()).toBe(T0)
  expect(w.bashCommands).toEqual([ST])
  expect(w.runs.map(r => r.argv)).toEqual([['/bin/sh', '-c', ST]])
  expect(w.runs[0]?.cwd).toBe(CWD)
  expect(ran.context).toContain(
    `poll-watcher dropped the sleep and ran \`${ST}\` now. It re-runs the command every 240 s and sends you a message when the output changes. Do not poll it again: end your turn or carry on with other work.`,
  )
  expect(await watches($)).toEqual([
    {
      command: ST,
      cwd: CWD,
      intervalMs: 240000,
      phase: 'watching',
      output: 'run: running',
      exitCode: 0,
      armedAt: T0,
      checkedAt: T0,
      changedAt: T0,
    },
  ])
  expect(w.status).toBe(`watching · ${ST} · run: running`)
})

test('unchanged tick stays quiet', WITH_PROBE, async ($, on) => {
  const w = world(on)
  await $.session.start(START)
  await $.tool.call({ tool: 'Bash', command: POLL })

  await w.clock.advance(240_000)

  expect(w.prompts).toEqual([])
  expect(await watchOne($)).toMatchObject({ checkedAt: T0 + 240_000, phase: 'watching', changedAt: T0 })
})

test('a change wakes the session once', WITH_PROBE, async ($, on) => {
  const w = await changedOnce($, on)

  expect(w.prompts).toEqual([`poll-watcher: \`${ST}\` changed. New output:\n\nrun: passed`])
  expect(await watchOne($)).toMatchObject({ phase: 'changed', output: 'run: passed', changedAt: T0 + 240_000 })
  expect(w.status).toBe(`changed · ${ST} · run: passed`)
})

test('ticks on quietly after the wake', WITH_PROBE, async ($, on) => {
  const w = await changedOnce($, on)

  w.output = 'run: merged'
  await w.clock.advance(240_000)

  expect(w.prompts).toHaveLength(1)
  expect(await watchOne($)).toMatchObject({ output: 'run: merged', phase: 'changed' })
})

test('volatile tokens do not count as change', WITH_PROBE, async ($, on) => {
  const w = world(on)
  w.output = 'build  pass  1m23s  12:01:33  2026-10-02T12:00:00Z  updated 3 minutes ago'
  await $.session.start(START)
  await $.tool.call({ tool: 'Bash', command: POLL })

  w.output = 'build  pass  2m05s  12:05:10  2026-10-02T12:04:00Z  updated 7 minutes ago'
  await w.clock.advance(240_000)

  expect(w.prompts).toEqual([])
  expect(await watchOne($)).toMatchObject({
    output: 'build  pass  2m05s  12:05:10  2026-10-02T12:04:00Z  updated 7 minutes ago',
  })

  w.output = 'build  fail  2m30s  12:05:40  2026-10-02T12:04:30Z  updated 8 minutes ago'
  await w.clock.advance(240_000)

  expect(w.prompts).toHaveLength(1)
})

test('stops after 60 min unchanged, telling a waiting model', WITH_PROBE, async ($, on) => {
  const w = await armed($, on)

  await w.clock.advance(3_600_000)

  expect((await watchOne($)).phase).toBe('stopped')
  expect(w.prompts).toEqual([
    `poll-watcher: \`${ST}\` unchanged for 60 min, stopped watching. Last output:\n\nrun: running`,
  ])
  const runs = w.runs.length
  await w.clock.advance(600_000)
  expect(w.runs).toHaveLength(runs)
})

test('a changed watch stops quietly', WITH_PROBE, async ($, on) => {
  const w = await changedOnce($, on)

  await w.clock.advance(3_600_000)

  expect((await watchOne($)).phase).toBe('stopped')
  expect(w.prompts).toHaveLength(1)
})

test('re-poll re-arms the wake', WITH_PROBE, async ($, on) => {
  const w = await changedOnce($, on)

  await $.tool.call({ tool: 'Bash', command: POLL })

  const list = await watches($)
  expect(list).toHaveLength(1)
  expect(list?.[0]).toMatchObject({ phase: 'watching', armedAt: T0 + 240_000 })

  w.output = 'run: merged'
  await w.clock.advance(240_000)

  expect(w.prompts).toEqual([
    `poll-watcher: \`${ST}\` changed. New output:\n\nrun: passed`,
    `poll-watcher: \`${ST}\` changed. New output:\n\nrun: merged`,
  ])
})

test('interval clamps', WITH_PROBE, async ($, on) => {
  world(on)
  await $.session.start(START)

  const short = await $.tool.call({ tool: 'Bash', command: 'sleep 2; gh pr checks' })
  const long = await $.tool.call({ tool: 'Bash', command: 'sleep 30m; gh pr view 12' })

  const byCommand = Object.fromEntries((await watches($))?.map(x => [x.command, x.intervalMs]) ?? [])
  expect(byCommand).toEqual({ 'gh pr checks': 15000, 'gh pr view 12': 600000 })
  expect(short.context?.join('\n')).toContain('every 15 s')
  expect(long.context?.join('\n')).toContain('every 600 s')
})

test('pass-through', WITH_PROBE, async ($, on) => {
  const w = world(on)
  await $.session.start(START)
  const commands = [
    'sleep 5; git push',
    'echo hi',
    'sleep 5; gh pr checks; rm -rf x',
    'sleep 5; gh pr checks > out.txt',
    'sleep 5 && gh pr checks || true',
    'sleep 5; gh pr checks $(cat id)',
    'sleep 5; gh pr checks & rm -rf x',
    'sleep 5; gh pr checks | xargs rm',
    'sleep 5; gh pr checks | tee out.txt',
    'sleep 5; gh pr checks | sed -n 1p',
  ]

  for (const command of commands) await $.tool.call({ tool: 'Bash', command })

  expect(w.bashCommands).toEqual(commands)
  expect(w.runs).toEqual([])
  expect((await watches($)) ?? []).toEqual([])
})

test('pipes and stderr merge are watched', WITH_PROBE, async ($, on) => {
  const w = world(on)
  await $.session.start(START)

  await $.tool.call({ tool: 'Bash', command: 'sleep 60 && gh pr checks 2>&1 | tail -5' })

  expect(w.bashCommands).toEqual(['gh pr checks 2>&1 | tail -5'])
  expect(await watchOne($)).toMatchObject({ command: 'gh pr checks 2>&1 | tail -5', intervalMs: 60000 })

  await $.tool.call({ tool: 'Bash', command: 'sleep 60; gh pr checks | grep fail | wc -l' })

  expect(w.bashCommands).toEqual(['gh pr checks 2>&1 | tail -5', 'gh pr checks | grep fail | wc -l'])
  expect(await watchOne($)).toMatchObject({ command: 'gh pr checks | grep fail | wc -l', intervalMs: 60000 })
})

test('non-interactive sessions pass through', WITH_PROBE, async ($, on) => {
  const w = world(on)
  await $.session.start({ ...START, isInteractive: false })

  await $.tool.call({ tool: 'Bash', command: POLL })

  expect(w.bashCommands).toEqual([POLL])
  expect((await watches($)) ?? []).toEqual([])
})

test('a deny arms nothing', WITH_PROBE, async ($, on) => {
  const w = world(on)
  w.bashAnswer = { deny: 'no' }
  await $.session.start(START)

  const ran = await $.tool.call({ tool: 'Bash', command: POLL })

  expect(ran).toEqual({ deny: 'no' })
  expect(w.runs).toEqual([])
  expect((await watches($)) ?? []).toEqual([])
})

test('background and interrupted runs arm nothing', WITH_PROBE, async ($, on) => {
  const w = world(on)
  await $.session.start(START)

  await $.tool.call({ tool: 'Bash', command: POLL, run_in_background: true })

  expect(w.bashCommands).toEqual([POLL])
  expect((await watches($)) ?? []).toEqual([])

  w.bashAnswer = { result: { stdout: '', stderr: '', interrupted: true } }
  await $.tool.call({ tool: 'Bash', command: POLL })

  expect((await watches($)) ?? []).toEqual([])
})

test('a failing run is a change', WITH_PROBE, async ($, on) => {
  const w = await armed($, on)

  w.runError = new Error('boom')
  await w.clock.advance(240_000)

  expect(w.prompts).toHaveLength(1)
  expect(w.prompts[0]).toContain('could not run: boom')
  expect((await watchOne($)).exitCode).toBe(-1)
})

test('a re-fired session.start does not double the timer', WITH_PROBE, async ($, on) => {
  const w = await armed($, on)
  const runs = w.runs.length

  await $.session.start(START)
  await w.clock.advance(240_000)

  expect(w.runs).toHaveLength(runs + 1)
})

// Beyond the contract's scenarios: the design's failure semantics for a
// baseline run that cannot start.
test('a baseline that cannot run arms nothing', WITH_PROBE, async ($, on) => {
  const w = world(on)
  w.runError = new Error('boom')
  await $.session.start(START)

  const ran = await $.tool.call({ tool: 'Bash', command: POLL })

  expect(w.bashCommands).toEqual([ST])
  expect(ran.context).toBeUndefined()
  expect((await watches($)) ?? []).toEqual([])
})

test('a re-fired session.start keeps a changed watch ticking to its stop', WITH_PROBE, async ($, on) => {
  const w = await changedOnce($, on)
  const runs = w.runs.length

  await $.session.start(START)
  await w.clock.advance(240_000)

  expect(w.runs).toHaveLength(runs + 1)

  await w.clock.set(T0 + 240_000 + 3_600_000)

  expect((await watchOne($)).phase).toBe('stopped')
  expect(w.prompts).toHaveLength(1)
})
