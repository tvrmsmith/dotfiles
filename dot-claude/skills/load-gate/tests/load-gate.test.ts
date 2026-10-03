import type { On, ToolCallResult } from 'claude-code'
import { expect, mock, test } from 'claude-code/testing'
import type { MockClock } from 'claude-code/testing'

// A signal the machine reports: a number as `memory_pressure` / `top` print
// it, or a way of failing to report it.
type Reading = number | 'rejects' | 'exits-1'

type Readings = { memory: Reading; cpu: Reading }

type World = {
  readings: Readings
  clock: MockClock
  // Commands that reached the bottom, i.e. actually ran.
  ran: string[]
  // Every argv the plugin handed `$.process.run`.
  runs: (readonly string[])[]
  statuses: (string | undefined)[]
  toasts: string[]
  // What the bottom Bash tool answers; the default is a plain success.
  answer: (command: string) => ToolCallResult
}

const OK = { exitCode: 0, stderr: '', isStdoutTruncated: false, isStderrTruncated: false }

// A hook beneath the plugins answers a call on `$` as `{ value }`.
const sample = (reading: Reading, stdout: (value: number) => string) => {
  if (reading === 'rejects') return Promise.reject(new Error('command not found'))
  if (reading === 'exits-1') return Promise.resolve({ value: { ...OK, exitCode: 1, stdout: '' } })
  return Promise.resolve({ value: { ...OK, stdout: stdout(reading) } })
}

const memoryOut = (m: number) => `System-wide memory free percentage: ${m}%\n`
const cpuOut = (c: number) =>
  `CPU usage: 50.00% user, 10.00% sys, 90.00% idle\nCPU usage: 10.00% user, 10.00% sys, ${c}% idle\n`

// Stands up the machine beneath the plugin: load samples, the hold child that
// exits once its flag file is written, the Bash tool, the status line, toasts.
const world = (on: On, readings: Readings): World => {
  const w: World = {
    readings,
    clock: mock.clock(on),
    ran: [],
    runs: [],
    statuses: [],
    toasts: [],
    answer: () => ({ result: { stdout: 'ok', stderr: '', interrupted: false }, text: 'ok' }),
  }
  const written = new Set<string>()
  const waiting = new Map<string, () => void>()

  on('process.run', ($, e) => {
    w.runs.push(e.argv)
    const [cmd] = e.argv
    if (cmd === 'memory_pressure') return sample(w.readings.memory, memoryOut)
    if (cmd === 'top') return sample(w.readings.cpu, cpuOut)
    if (cmd === 'sh') {
      const flag = e.argv.at(-1) ?? ''
      return new Promise(resolve => {
        const exit = () => resolve({ value: { ...OK, stdout: '' } })
        if (written.has(flag)) exit()
        else waiting.set(flag, exit)
      })
    }
    throw new Error(`unexpected process.run ${e.argv.join(' ')}`)
  })
  on('fs.write', ($, e) => {
    written.add(e.path)
    waiting.get(e.path)?.()
    waiting.delete(e.path)
    return { value: undefined }
  })
  on('ui.status', ($, e) => {
    w.statuses.push(e.text)
    return { value: undefined }
  })
  on('ui.toast', ($, e) => {
    w.toasts.push(e.text)
    return { value: undefined }
  })
  on('tool.call', { tool: 'Bash' }, ($, e) => {
    w.ran.push(e.command)
    return w.answer(e.command)
  })
  return w
}

const HEALTHY: Readings = { memory: 46, cpu: 37.17 }

const children = (w: World) => w.runs.filter(argv => argv[0] === 'sh')

test('a test run on a healthy machine runs at once, untouched', async ($, on) => {
  const w = world(on, { ...HEALTHY })

  const result = await $.tool.call({ tool: 'Bash', command: 'dotnet test src/App.Tests' })

  expect(w.ran).toEqual(['dotnet test src/App.Tests'])
  expect(result.context ?? []).toEqual([])
  expect(w.statuses).toEqual([])
  expect(children(w)).toEqual([])
})

const BUSY: Readings = { memory: 5, cpu: 2 }

test('a command that is not a test run passes at once without sampling', async ($, on) => {
  const w = world(on, { ...BUSY })
  const commands = ['git status', 'grep -rn "go test" docs/', 'echo bats']

  for (const command of commands) await $.tool.call({ tool: 'Bash', command })

  expect(w.ran).toEqual(commands)
  expect(w.runs).toEqual([])
})

const memorySamples = (w: World) => w.runs.filter(argv => argv[0] === 'memory_pressure')

test('each test runner form is sampled, then runs on a healthy machine', async ($, on) => {
  const w = world(on, { ...HEALTHY })
  const commands = [
    'CI=1 npx vitest run',
    'uv run pytest -q',
    'npm run test:unit',
    'cd api && pnpm test',
    'go test ./...',
    'bats tests/',
    'cd api\nnpm test',
  ]

  for (const command of commands) {
    const before = memorySamples(w).length
    await $.tool.call({ tool: 'Bash', command })
    expect(memorySamples(w).length, `sampled for ${JSON.stringify(command)}`).toBe(before + 1)
  }

  expect(w.ran).toEqual(commands)
})

const TICK = 30_000

test('low memory holds a test run until a tick finds the machine free', async ($, on) => {
  const w = world(on, { memory: 8, cpu: 50 })

  const call = $.tool.call({ tool: 'Bash', command: 'cd api && pnpm test' })
  await w.clock.settle()

  expect(w.ran).toEqual([])
  expect(w.statuses.at(-1)).toBe('load-gate: 1 held (memory 8% free, CPU 50% idle)')

  w.readings.memory = 35
  await w.clock.advance(TICK)
  const result = await call

  const released =
    'load-gate: held the tests 30s until the machine freed up (was memory 8% free, CPU 50% idle, now memory 35% free, CPU 50% idle).'
  expect(w.ran).toEqual(['cd api && pnpm test'])
  expect(result.context?.at(-1)).toBe(released)
  expect(w.toasts).toEqual([released])
  expect(w.statuses.at(-1)).toBeUndefined()
  expect(w.statuses.length).toBeGreaterThan(1)
})

test('low idle CPU alone holds a test run', async ($, on) => {
  const w = world(on, { memory: 60, cpu: 4 })

  const call = $.tool.call({ tool: 'Bash', command: 'go test ./...' })
  await w.clock.settle()

  expect(w.ran).toEqual([])
  expect(w.statuses.at(-1)).toBe('load-gate: 1 held (memory 60% free, CPU 4% idle)')

  w.readings.cpu = 40
  await w.clock.advance(TICK)
  await call

  expect(w.ran).toEqual(['go test ./...'])
})

test('a machine that stays busy releases the run at the cap', async ($, on) => {
  const w = world(on, { ...BUSY })

  const call = $.tool.call({ tool: 'Bash', command: 'go test ./...' })
  await w.clock.settle()
  expect(w.ran).toEqual([])

  await w.clock.advance(590_000)
  const result = await call

  expect(w.ran).toEqual(['go test ./...'])
  expect(result.context?.at(-1)).toBe(
    'load-gate: machine stayed busy for 590s (was memory 5% free, CPU 2% idle, now memory 5% free, CPU 2% idle); running the tests anyway, so expect them to be slow.',
  )
})

test('a signal that cannot be read never holds a test run', async ($, on) => {
  const unreadable: Readings[] = [
    { memory: 'rejects', cpu: 37 },
    { memory: 'exits-1', cpu: 37 },
    { memory: 'rejects', cpu: 'rejects' },
  ]

  const w = world(on, { ...HEALTHY })
  for (const readings of unreadable) {
    w.readings = readings
    await $.tool.call({ tool: 'Bash', command: 'bats tests/' })
  }

  expect(w.ran).toEqual(['bats tests/', 'bats tests/', 'bats tests/'])
  expect(children(w)).toEqual([])
})

test('held runs leave in arrival order, one per tick', async ($, on) => {
  const w = world(on, { ...BUSY })

  const a = $.tool.call({ tool: 'Bash', command: 'go test ./a' })
  await w.clock.settle()
  const b = $.tool.call({ tool: 'Bash', command: 'go test ./b' })
  await w.clock.settle()
  expect(w.statuses.at(-1)).toBe('load-gate: 2 held (memory 5% free, CPU 2% idle)')

  w.readings = { memory: 46, cpu: 37 }
  await w.clock.advance(TICK)
  await a
  expect(w.ran).toEqual(['go test ./a'])
  expect(w.statuses.at(-1)).toBe('load-gate: 1 held (memory 46% free, CPU 37% idle)')

  await w.clock.advance(TICK)
  await b
  expect(w.ran).toEqual(['go test ./a', 'go test ./b'])
  expect(w.statuses.at(-1)).toBeUndefined()
})

test('a test run arriving on a free machine still queues behind held runs', async ($, on) => {
  const w = world(on, { ...BUSY })

  const a = $.tool.call({ tool: 'Bash', command: 'go test ./a' })
  await w.clock.settle()

  w.readings = { memory: 46, cpu: 37 }
  const c = $.tool.call({ tool: 'Bash', command: 'go test ./c' })
  await w.clock.settle()
  expect(w.ran).toEqual([])
  expect(w.statuses.at(-1)).toBe('load-gate: 2 held (memory 46% free, CPU 37% idle)')

  await w.clock.advance(TICK)
  await a
  expect(w.ran).toEqual(['go test ./a'])

  await w.clock.advance(TICK)
  await c
  expect(w.ran).toEqual(['go test ./a', 'go test ./c'])
})

test('a released run keeps the context the tool returned', async ($, on) => {
  const w = world(on, { memory: 8, cpu: 50 })
  w.answer = () => ({ result: { stdout: 'ok', stderr: '', interrupted: false }, text: 'ok', context: ['prior'] })

  const call = $.tool.call({ tool: 'Bash', command: 'go test ./...' })
  await w.clock.settle()
  w.readings.memory = 35
  await w.clock.advance(TICK)

  expect((await call).context).toEqual([
    'prior',
    'load-gate: held the tests 30s until the machine freed up (was memory 8% free, CPU 50% idle, now memory 35% free, CPU 50% idle).',
  ])
})

test('a deny from beneath on a healthy run comes back untouched', async ($, on) => {
  const w = world(on, { ...HEALTHY })
  w.answer = () => ({ deny: 'nope' })

  const result = await $.tool.call({ tool: 'Bash', command: 'go test ./...' })

  expect(result).toEqual({ deny: 'nope' })
})
