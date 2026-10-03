import type { EngineInterface, ModelCompleteResult, ProcessSpawnChunk, ProcessSpawnResult, Register } from 'claude-code'

const RESUME_TEXT = 'continue'
const MAX_ATTEMPTS = 20
const MAX_RESUMES = 3
const STALE_MS = 24 * 60 * 60_000
const KEY_PREFIX = 'pending:'
const PLUGIN_NAME = 'outage-resume'
const DEFAULT_API_HOST = 'api.anthropic.com'
const PROBE_TIMEOUT_MS = 20_000
const ERROR_PREFIX = 'API Error:'
const LOGIN_PATTERN = /\/login|session expired/i

type Pending = {
  /** The number of the next attempt to run. */
  attempt: number
  /** Continues submitted since the last answered turn. */
  resumes: number
  dueAt: number
}

type SpawnStream = AsyncGenerator<ProcessSpawnChunk, ProcessSpawnResult>

let isAttempting = false
let cancelTimer: (() => void) | undefined
let watcher: SpawnStream | undefined

const backoff = (attempt: number): number => Math.min(30_000 * 2 ** (attempt - 1), 300_000)

const pendingKey = (sessionId: string): string => `${KEY_PREFIX}${sessionId}`

/** Parses a stored value at the boundary; a record this module did not write reads as absent. */
function parsePending(value: unknown): Pending | undefined {
  if (typeof value !== 'object' || value === null) {
    return undefined
  }
  const { attempt, resumes, dueAt } = value as Record<string, unknown>
  const isValid =
    Number.isInteger(attempt) &&
    (attempt as number) >= 1 &&
    (attempt as number) <= MAX_ATTEMPTS &&
    Number.isInteger(resumes) &&
    (resumes as number) >= 0 &&
    typeof dueAt === 'number' &&
    Number.isFinite(dueAt)
  return isValid ? (value as Pending) : undefined
}

async function readPending($: EngineInterface, sessionId: string): Promise<Pending | undefined> {
  return parsePending(await $.store.get(pendingKey(sessionId)))
}

async function sweepStale($: EngineInterface, sessionId: string): Promise<void> {
  const now = await $.clock.now()
  for (const key of await $.store.keys()) {
    if (!key.startsWith(KEY_PREFIX) || key === pendingKey(sessionId)) {
      continue
    }
    const other = parsePending(await $.store.get(key))
    if (other !== undefined && other.dueAt < now - STALE_MS) {
      await $.store.delete(key)
    }
  }
}

/** The one place a timer is cancelled, a record stored and the next attempt scheduled. */
async function arm($: EngineInterface, sessionId: string, pending: Pending): Promise<void> {
  cancelTimer?.()
  await $.store.set(pendingKey(sessionId), pending)
  const delay = Math.max(pending.dueAt - (await $.clock.now()), 0)
  cancelTimer = $.clock.after(delay, () => void runAttempt($, sessionId)).cancel
  await startWatcher($, sessionId)
}

const PERSON_ORIGINS: readonly string[] = ['composer', 'bridge', 'sdk']
const REFUSED_ERRORS: readonly string[] = ['invalid_request', 'model_not_found', 'billing_error']

type Verdict = { kind: 'back' | 'login' | 'retry' } | { kind: 'refused'; error: string }

function judge(probe: ModelCompleteResult): Verdict {
  if (probe.isAnswered || probe.reason === 'empty-reply') {
    return { kind: 'back' }
  }
  if (probe.reason === 'api-error') {
    if (probe.status === 401 || probe.status === 403 || probe.error === 'authentication_failed') {
      return { kind: 'login' }
    }
    if (REFUSED_ERRORS.includes(probe.error)) {
      return { kind: 'refused', error: probe.error }
    }
  }
  return { kind: 'retry' }
}

function stopWatcher(): void {
  const running = watcher
  watcher = undefined
  // Returning the stream kills the child. A child that already ended has nothing to stop.
  void running?.return({ code: null, signal: null }).catch(() => undefined)
}

function stop(): void {
  cancelTimer?.()
  cancelTimer = undefined
  stopWatcher()
}

async function apiHost($: EngineInterface): Promise<string> {
  const baseUrl = await $.env.get('ANTHROPIC_BASE_URL')
  if (baseUrl === undefined) {
    return DEFAULT_API_HOST
  }
  try {
    return new URL(baseUrl).hostname
  } catch {
    return DEFAULT_API_HOST
  }
}

/** Yields the child's output and ends quietly when it cannot start or dies (no scutil off macOS). The backoff timer covers it. */
async function* output(stream: SpawnStream): AsyncGenerator<ProcessSpawnChunk> {
  try {
    yield* stream
  } catch {
    return
  }
}

/** Runs the attempt now when the network returns after having been seen down. */
async function watch($: EngineInterface, sessionId: string, stream: SpawnStream): Promise<void> {
  let wasUnreachable = false
  for await (const chunk of output(stream)) {
    for (const line of chunk.text.split('\n')) {
      if (line.startsWith('Not Reachable')) {
        wasUnreachable = true
      } else if (line.startsWith('Reachable') && wasUnreachable) {
        wasUnreachable = false
        cancelTimer?.()
        await runAttempt($, sessionId)
      }
    }
    if (watcher !== stream) {
      return
    }
  }
}

async function startWatcher($: EngineInterface, sessionId: string): Promise<void> {
  if (watcher !== undefined) {
    return
  }
  const stream = $.process.spawn({ argv: ['scutil', '-r', '-W', await apiHost($)] })
  watcher = stream
  void watch($, sessionId, stream)
}

async function clear($: EngineInterface, sessionId: string): Promise<void> {
  stop()
  await $.store.delete(pendingKey(sessionId))
}

async function offerLogin($: EngineInterface, sessionId: string): Promise<void> {
  $.ui.toast('Login expired. Run /login to reconnect.')
  await $.prompt.suggest({ text: '/login' })
  await clear($, sessionId)
}

async function runAttempt($: EngineInterface, sessionId: string): Promise<void> {
  if (isAttempting) {
    return
  }
  isAttempting = true
  try {
    await probeAndDecide($, sessionId)
  } finally {
    isAttempting = false
  }
}

async function probeAndDecide($: EngineInterface, sessionId: string): Promise<void> {
  const started = await readPending($, sessionId)
  if (started === undefined) {
    return
  }
  const n = started.attempt
  $.ui.toast(`API unreachable. Retry ${n} of ${MAX_ATTEMPTS}.`)
  const probe = await $.model.complete({
    model: await $.session.model(),
    prompt: 'ping',
    maxTokens: 1,
    timeoutMs: PROBE_TIMEOUT_MS,
  })
  // The person may have typed a prompt while the probe ran, which clears the record.
  const pending = await readPending($, sessionId)
  if (pending === undefined) {
    return
  }
  const verdict = judge(probe)
  if (verdict.kind === 'login') {
    await offerLogin($, sessionId)
    return
  }
  if (verdict.kind === 'refused') {
    $.ui.toast(`API refused the retry (${verdict.error}). Not resuming.`)
    await clear($, sessionId)
    return
  }
  const next: Pending = {
    attempt: n + 1,
    resumes: pending.resumes + (verdict.kind === 'back' ? 1 : 0),
    dueAt: (await $.clock.now()) + backoff(n + 1),
  }
  if (verdict.kind === 'back') {
    // Stored before the submit so a fast resumed turn that clears the key is not undone by a late write.
    await $.store.set(pendingKey(sessionId), next)
    stopWatcher()
    $.ui.toast('API is back. Resuming.')
    await $.prompt.submit({ text: RESUME_TEXT })
    return
  }
  if (n >= MAX_ATTEMPTS) {
    $.ui.toast(`API still unreachable after ${MAX_ATTEMPTS} retries. Type continue to resume.`)
    await clear($, sessionId)
    return
  }
  await arm($, sessionId, next)
}

/** The text of the session's last message when it is an API error, else undefined. */
async function lastApiError($: EngineInterface): Promise<string | undefined> {
  const last = (await $.session.messages()).at(-1)
  return last?.role === 'assistant' && last.text.startsWith(ERROR_PREFIX) ? last.text : undefined
}

async function onMainLoopError($: EngineInterface, sessionId: string): Promise<void> {
  const errorText = await lastApiError($)
  if (errorText === undefined) {
    return
  }
  if (LOGIN_PATTERN.test(errorText)) {
    await offerLogin($, sessionId)
    return
  }
  const pending = (await readPending($, sessionId)) ?? { attempt: 1, resumes: 0, dueAt: 0 }
  if (pending.resumes >= MAX_RESUMES) {
    $.ui.toast(`Resumed ${MAX_RESUMES} times and the turn still failed. Not resuming.`)
    await clear($, sessionId)
    return
  }
  await arm($, sessionId, {
    ...pending,
    dueAt: (await $.clock.now()) + backoff(pending.attempt),
  })
}

export const register: Register = on => {
  on('turn.complete', async ($, e, next) => {
    if (e.agentId === undefined) {
      const sessionId = await $.session.id()
      if (e.reason === 'error') {
        await onMainLoopError($, sessionId)
      } else {
        await clear($, sessionId)
      }
    }
    return next(e)
  })

  on('session.start', async ($, e, next) => {
    const started = await next(e)
    const sessionId = await $.session.id()
    await sweepStale($, sessionId)
    const pending = await readPending($, sessionId)
    if (pending !== undefined) {
      await arm($, sessionId, pending)
    }
    return started
  })

  on('prompt.submit', async ($, e, next) => {
    if (PERSON_ORIGINS.includes(e.origin.kind)) {
      await clear($, await $.session.id())
    }
    return next(e)
  })

  on('ui.render', { component: 'UserMessage' }, ($, e, next) => {
    const { origin, isExpanded } = e.props
    if (origin.kind !== 'plugin' || origin.name !== PLUGIN_NAME || isExpanded) {
      return next(e)
    }
    const { Text } = $.ui.resolve(e)
    return <Text dimColor>↻ resumed after an API outage</Text>
  })

  on('session.end', async ($, e, next) => {
    if (e.reason === 'clear') {
      await clear($, e.sessionId)
    } else {
      stop()
    }
    return next(e)
  })
}
