import { expect, mock } from 'claude-code/testing'
import type { MockClock } from 'claude-code/testing'
import type {
  ModelCompleteRequest,
  ModelCompleteResult,
  On,
  ProcessSpawnChunk,
  ProcessSpawnRequest,
  PromptSubmitInput,
  SessionMessage,
} from 'claude-code'

const USAGE = { input_tokens: 0, output_tokens: 0 }

export const ANSWERED: ModelCompleteResult = {
  isAnswered: true,
  text: 'pong',
  usage: USAGE,
} as ModelCompleteResult

export const apiError = (error: string, status: number | null): ModelCompleteResult =>
  ({ isAnswered: false, reason: 'api-error', status, error, usage: USAGE }) as ModelCompleteResult

export const NETWORK_ERROR = 'API Error: Connection dropped (ECONNRESET)'
export const LOGIN_ERROR = 'API Error: Session expired — run /login to reconnect.'

export type SpawnScript = (request: ProcessSpawnRequest) => AsyncGenerator<ProcessSpawnChunk, void>

export type WorldOptions = {
  now?: number
  store?: Record<string, unknown>
  env?: Record<string, string>
  spawn?: SpawnScript
}

/** Stands in for the engine beneath the plugin and records what reached it. */
export type World = {
  clock: MockClock
  toasts: string[]
  submits: PromptSubmitInput[]
  suggests: { text: string }[]
  probes: ModelCompleteRequest[]
  spawns: ProcessSpawnRequest[]
  /** The key-value store as the plugin left it. mock.store hides its contents, so the harness keeps its own. */
  store: Record<string, unknown>
  /** What the last message of the session says. */
  lastMessage: SessionMessage
  /** What the probe answers, by the number of probes made so far (1-based). */
  probeAnswer: (call: number) => ModelCompleteResult
  /** How long the mock clock must move before a probe resolves. */
  probeDelayMs: number
  /** The pending record as the store held it at each prompt.submit. */
  pendingAtSubmit: unknown[]
}

export function createWorld(on: On, options: WorldOptions = {}): World {
  const clock = mock.clock(on, { now: options.now ?? 0 })
  mock.env(on, options.env ?? {})

  const world: World = {
    clock,
    toasts: [],
    submits: [],
    suggests: [],
    probes: [],
    spawns: [],
    store: { ...options.store },
    lastMessage: { role: 'assistant', text: NETWORK_ERROR, toolUses: [] },
    probeAnswer: () => ANSWERED,
    probeDelayMs: 0,
    pendingAtSubmit: [],
  }

  on('store.get', (_$, e) => ({ value: world.store[e.key] }))
  on('store.set', (_$, e) => {
    world.store[e.key] = JSON.parse(JSON.stringify(e.value))
    return { value: undefined }
  })
  on('store.delete', (_$, e) => {
    delete world.store[e.key]
    return { value: undefined }
  })
  on('store.keys', () => ({ value: Object.keys(world.store) }))
  on('turn.complete', (_$, e) => ({ text: e.answer }))
  on('session.start', (_$, e) => ({ cwd: e.cwd }))
  on('session.end', (_$, e) => ({ sessionId: e.sessionId }))
  on('session.id', () => ({ value: 's1' }))
  on('session.model', () => ({ value: 'test-model' }))
  on('session.messages', () => ({ value: [world.lastMessage] }))
  on('ui.toast', (_$, e) => {
    world.toasts.push(e.text)
    return { value: undefined }
  })
  on('prompt.suggest', (_$, e) => {
    world.suggests.push({ text: e.text })
    return { isShown: true }
  })
  on('prompt.submit', (_$, e) => {
    world.submits.push(e)
    world.pendingAtSubmit.push(structuredClone(world.store['pending:s1']))
    return { text: e.text }
  })
  on('model.complete', async (_$, e) => {
    world.probes.push(e)
    const answer = world.probeAnswer(world.probes.length)
    if (world.probeDelayMs > 0) {
      await clock.sleep(world.probeDelayMs)
    }
    return { value: answer }
  })
  on('process.spawn', async function* (_$, e) {
    world.spawns.push(e)
    if (options.spawn !== undefined) {
      yield* options.spawn(e)
    }
    return { value: { code: 0, signal: null } }
  })

  return world
}

export const errorTurn = {
  answer: '',
  durationMs: 0,
  isAborted: false,
  turnId: 't1',
  reason: 'error',
} as const

export { expect }

export const sessionStart = {
  cwd: '/work',
  surface: 'terminal',
  isInteractive: true,
} as const
