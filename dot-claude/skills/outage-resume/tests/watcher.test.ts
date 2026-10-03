import { test } from 'claude-code/testing'

import { ANSWERED, type SpawnScript, apiError, createWorld, errorTurn, expect } from './harness'

/** A scutil stand-in: each step waits until `at` ms on the mock clock, then prints `text`. */
const scutilSays =
  (clock: () => { sleep: (ms: number) => Promise<void>; now: () => number }, steps: [number, string][]): SpawnScript =>
  async function* () {
    for (const [at, text] of steps) {
      await clock().sleep(at - clock().now())
      yield { stream: 'stdout', text }
    }
  }

test('a network that comes back wakes the attempt before the backoff timer', async ($, on) => {
  let world!: ReturnType<typeof createWorld>
  world = createWorld(on, {
    spawn: scutilSays(() => world.clock, [
      [0, 'Not Reachable\n'],
      [10_000, 'Reachable\n'],
    ]),
  })

  await $.turn.complete(errorTurn)
  await world.clock.advance(9_999)
  expect(world.probes).toHaveLength(0)

  await world.clock.advance(1)
  expect(world.probes).toHaveLength(1)
  expect(world.toasts).toEqual(['API unreachable. Retry 1 of 20.', 'API is back. Resuming.'])

  await world.clock.advance(10 * 60_000)
  expect(world.probes).toHaveLength(1)
  expect(world.submits).toHaveLength(1)
})

test('watches the default API host with scutil when no base URL is set', async ($, on) => {
  const world = createWorld(on)

  await $.turn.complete(errorTurn)
  await world.clock.settle()

  expect(world.spawns.map(s => s.argv)).toEqual([['scutil', '-r', '-W', 'api.anthropic.com']])
})

test('watches the host of ANTHROPIC_BASE_URL when it is set', async ($, on) => {
  const world = createWorld(on, { env: { ANTHROPIC_BASE_URL: 'https://gateway.example.test/v1' } })

  await $.turn.complete(errorTurn)
  await world.clock.settle()

  expect(world.spawns.map(s => s.argv)).toEqual([['scutil', '-r', '-W', 'gateway.example.test']])
})

test('a first Reachable with no Not Reachable before it wakes nothing', async ($, on) => {
  let world!: ReturnType<typeof createWorld>
  world = createWorld(on, { spawn: scutilSays(() => world.clock, [[0, 'Reachable\n']]) })

  await $.turn.complete(errorTurn)
  await world.clock.advance(29_999)

  expect(world.probes).toHaveLength(0)
})

test('Not Reachable and Reachable lines in one chunk still wake the attempt', async ($, on) => {
  let world!: ReturnType<typeof createWorld>
  world = createWorld(on, { spawn: scutilSays(() => world.clock, [[0, 'Not Reachable\nReachable\n']]) })

  await $.turn.complete(errorTurn)
  await world.clock.settle()

  expect(world.probes).toHaveLength(1)
})

test('a spawn that rejects is ignored and the timer still resumes', async ($, on) => {
  let world!: ReturnType<typeof createWorld>
  world = createWorld(on, {
    // eslint-disable-next-line require-yield
    spawn: async function* () {
      throw new Error('scutil: not found')
    },
  })

  await $.turn.complete(errorTurn)
  await world.clock.advance(30_000)

  expect(world.submits.map(s => s.text)).toEqual(['continue'])
})

test('one watcher serves every attempt of an outage', async ($, on) => {
  const world = createWorld(on)
  world.probeAnswer = call => (call < 3 ? apiError('server_error', 503) : ANSWERED)

  await $.turn.complete(errorTurn)
  await world.clock.advance(10 * 60_000)

  expect(world.probes).toHaveLength(3)
  expect(world.spawns).toHaveLength(1)
})

test('the watcher child is stopped once the resume is submitted', async ($, on) => {
  let isRunning = false
  let world!: ReturnType<typeof createWorld>
  world = createWorld(on, {
    spawn: async function* () {
      isRunning = true
      try {
        yield { stream: 'stdout', text: 'Not Reachable\n' }
        for (;;) {
          await world.clock.sleep(1_000)
          yield { stream: 'stdout', text: '\n' }
        }
      } finally {
        isRunning = false
      }
    },
  })

  await $.turn.complete(errorTurn)
  await world.clock.settle()
  expect(isRunning).toBe(true)

  await world.clock.advance(30_000)
  expect(world.submits).toHaveLength(1)
  await world.clock.advance(1_000)
  expect(isRunning).toBe(false)
})

test('a wake while a probe is in flight does not start a second attempt', async ($, on) => {
  let world!: ReturnType<typeof createWorld>
  world = createWorld(on, {
    spawn: scutilSays(() => world.clock, [
      [0, 'Not Reachable\n'],
      [32_000, 'Reachable\n'],
    ]),
  })
  world.probeDelayMs = 5_000

  await $.turn.complete(errorTurn)
  await world.clock.advance(40_000)

  expect(world.probes).toHaveLength(1)
  expect(world.submits).toHaveLength(1)
})
