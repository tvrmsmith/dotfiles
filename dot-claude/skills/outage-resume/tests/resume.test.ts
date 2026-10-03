import type { ModelCompleteResult } from 'claude-code'
import { test } from 'claude-code/testing'

import {
  ANSWERED,
  LOGIN_ERROR,
  apiError,
  createWorld,
  errorTurn,
  expect,
  sessionStart,
} from './harness'

test('resumes with continue once the API answers, with no typed prompt', async ($, on) => {
  const world = createWorld(on)

  await $.turn.complete(errorTurn)

  await world.clock.advance(29_999)
  expect(world.probes).toHaveLength(0)

  await world.clock.advance(1)
  expect(world.probes).toHaveLength(1)
  expect(world.submits.map(s => s.text)).toEqual(['continue'])
  expect(world.toasts).toEqual(['API unreachable. Retry 1 of 20.', 'API is back. Resuming.'])
})

test('a failed probe backs off to attempt 2 and resumes when it answers', async ($, on) => {
  const world = createWorld(on)
  world.probeAnswer = call => (call === 1 ? apiError('server_error', 503) : ANSWERED)

  await $.turn.complete(errorTurn)
  await world.clock.advance(30_000)

  expect(world.submits).toHaveLength(0)
  expect(world.store['pending:s1']).toEqual({ attempt: 2, resumes: 0, dueAt: 90_000 })

  await world.clock.advance(59_999)
  expect(world.probes).toHaveLength(1)

  await world.clock.advance(1)
  expect(world.probes).toHaveLength(2)
  expect(world.submits.map(s => s.text)).toEqual(['continue'])
})

test('an expired login offers /login and never probes or retries', async ($, on) => {
  const world = createWorld(on)
  world.lastMessage = { role: 'assistant', text: LOGIN_ERROR, toolUses: [] }

  await $.turn.complete(errorTurn)
  await world.clock.advance(10 * 60_000)

  expect(world.toasts).toEqual(['Login expired. Run /login to reconnect.'])
  expect(world.suggests).toEqual([{ text: '/login' }])
  expect(world.probes).toHaveLength(0)
  expect(world.submits).toHaveLength(0)
  expect(world.store['pending:s1']).toBeUndefined()
})

test('a probe refused with 401 turns into the login offer, with no resume', async ($, on) => {
  const world = createWorld(on)
  world.probeAnswer = () => apiError('unknown', 401)

  await $.turn.complete(errorTurn)
  await world.clock.advance(30_000)

  expect(world.toasts).toEqual([
    'API unreachable. Retry 1 of 20.',
    'Login expired. Run /login to reconnect.',
  ])
  expect(world.suggests).toEqual([{ text: '/login' }])
  expect(world.submits).toHaveLength(0)
  expect(world.store['pending:s1']).toBeUndefined()

  await world.clock.advance(10 * 60_000)
  expect(world.probes).toHaveLength(1)
})

test('a probe the API refuses outright stops the loop and names the error', async ($, on) => {
  const world = createWorld(on)
  world.probeAnswer = () => apiError('model_not_found', 404)

  await $.turn.complete(errorTurn)
  await world.clock.advance(30_000)

  expect(world.toasts).toEqual([
    'API unreachable. Retry 1 of 20.',
    'API refused the retry (model_not_found). Not resuming.',
  ])
  expect(world.submits).toHaveLength(0)
  expect(world.store['pending:s1']).toBeUndefined()
  await world.clock.advance(10 * 60_000)
  expect(world.probes).toHaveLength(1)
})

test('a probe failing with authentication_failed and no status is a login offer', async ($, on) => {
  const world = createWorld(on)
  world.probeAnswer = () => apiError('authentication_failed', null)

  await $.turn.complete(errorTurn)
  await world.clock.advance(30_000)

  expect(world.suggests).toEqual([{ text: '/login' }])
  expect(world.submits).toHaveLength(0)
})

test('a probe the model answers with no text still counts as the API being back', async ($, on) => {
  const world = createWorld(on)
  world.probeAnswer = () => ({ isAnswered: false, reason: 'empty-reply', usage: ANSWERED.usage }) as ModelCompleteResult

  await $.turn.complete(errorTurn)
  await world.clock.advance(30_000)

  expect(world.submits.map(s => s.text)).toEqual(['continue'])
})

test('gives up after 20 failed probes and tells the person to type continue', async ($, on) => {
  const world = createWorld(on)
  world.probeAnswer = () => apiError('server_error', 503)

  await $.turn.complete(errorTurn)
  await world.clock.advance(3 * 60 * 60_000)

  expect(world.probes).toHaveLength(20)
  expect(world.toasts.at(-1)).toBe('API still unreachable after 20 retries. Type continue to resume.')
  expect(world.toasts.at(-2)).toBe('API unreachable. Retry 20 of 20.')
  expect(world.submits).toHaveLength(0)
  expect(world.store['pending:s1']).toBeUndefined()
})

test('stops resuming after three continues whose turn still failed', async ($, on) => {
  const world = createWorld(on)

  for (let cycle = 1; cycle <= 3; cycle++) {
    await $.turn.complete(errorTurn)
    await world.clock.advance(300_000)
    expect(world.submits).toHaveLength(cycle)
  }

  await $.turn.complete(errorTurn)
  await world.clock.advance(60 * 60_000)

  expect(world.toasts.at(-1)).toBe('Resumed 3 times and the turn still failed. Not resuming.')
  expect(world.submits).toHaveLength(3)
  expect(world.probes).toHaveLength(3)
  expect(world.spawns).toHaveLength(3)
  expect(world.store['pending:s1']).toBeUndefined()
})

for (const reason of ['answer', 'aborted', 'refusal'] as const) {
  test(`a main-loop turn that ends in ${reason} clears the pending resume`, async ($, on) => {
    const world = createWorld(on)
    await $.turn.complete(errorTurn)
    expect(world.store['pending:s1']).toEqual({ attempt: 1, resumes: 0, dueAt: 30_000 })

    await $.turn.complete({
      ...errorTurn,
      reason,
      ...(reason === 'refusal' ? { refusal: { message: 'no' } } : {}),
    } as Parameters<typeof $.turn.complete>[0])
    await world.clock.advance(10 * 60_000)

    expect(world.store['pending:s1']).toBeUndefined()
    expect(world.probes).toHaveLength(0)
  })
}

test('a subagent error turn schedules nothing', async ($, on) => {
  const world = createWorld(on)

  await $.turn.complete({ ...errorTurn, agentId: 'agent-1' })
  await world.clock.advance(10 * 60_000)

  expect(world.store['pending:s1']).toBeUndefined()
  expect(world.probes).toHaveLength(0)
})

test('a subagent answered turn leaves a main-loop pending resume alone', async ($, on) => {
  const world = createWorld(on)
  await $.turn.complete(errorTurn)

  await $.turn.complete({ ...errorTurn, reason: 'answer', agentId: 'agent-1' })
  expect(world.store['pending:s1']).toEqual({ attempt: 1, resumes: 0, dueAt: 30_000 })

  await world.clock.advance(30_000)

  expect(world.submits.map(s => s.text)).toEqual(['continue'])
  expect(world.probes).toHaveLength(1)
})

test('/clear drops the pending resume', async ($, on) => {
  const world = createWorld(on)
  await $.turn.complete(errorTurn)

  await $.session.end({ reason: 'clear', sessionId: 's1' } as Parameters<typeof $.session.end>[0])
  await world.clock.advance(10 * 60_000)

  expect(world.store['pending:s1']).toBeUndefined()
  expect(world.probes).toHaveLength(0)
})

for (const kind of ['composer', 'bridge', 'sdk'] as const) {
  test(`a prompt from the person (${kind}) cancels the pending resume`, async ($, on) => {
    const world = createWorld(on)
    await $.turn.complete(errorTurn)

    await $.prompt.submit({ text: 'try this instead', wait: false, origin: { kind } })
    await world.clock.advance(10 * 60_000)

    expect(world.store['pending:s1']).toBeUndefined()
    expect(world.probes).toHaveLength(0)
  })
}

test('a prompt submitted by the plugin itself keeps the pending resume', async ($, on) => {
  const world = createWorld(on)
  await $.turn.complete(errorTurn)

  await $.prompt.submit({
    text: 'continue',
    wait: false,
    origin: { kind: 'plugin', name: 'outage-resume' },
  })

  expect(world.store['pending:s1']).toEqual({ attempt: 1, resumes: 0, dueAt: 30_000 })
  await world.clock.advance(30_000)
  expect(world.probes).toHaveLength(1)
})

test('a restart runs an overdue pending attempt right away', async ($, on) => {
  const world = createWorld(on, {
    now: 10_000,
    store: { 'pending:s1': { attempt: 3, resumes: 0, dueAt: 5_000 } },
  })

  await $.session.start(sessionStart)
  await world.clock.settle()

  expect(world.toasts).toEqual(['API unreachable. Retry 3 of 20.', 'API is back. Resuming.'])
  expect(world.submits.map(s => s.text)).toEqual(['continue'])
})

test('a restart waits out the rest of a pending delay', async ($, on) => {
  const world = createWorld(on, {
    now: 10_000,
    store: { 'pending:s1': { attempt: 2, resumes: 1, dueAt: 40_000 } },
  })

  await $.session.start(sessionStart)
  await world.clock.advance(29_999)
  expect(world.probes).toHaveLength(0)

  await world.clock.advance(1)
  expect(world.toasts).toEqual(['API unreachable. Retry 2 of 20.', 'API is back. Resuming.'])
  expect(world.store['pending:s1']).toEqual({ attempt: 3, resumes: 2, dueAt: 40_000 + 120_000 })
})

test('a restart deletes other sessions pending records older than 24 hours only', async ($, on) => {
  const hour = 60 * 60_000
  const world = createWorld(on, {
    now: 100 * hour,
    store: {
      'pending:old': { attempt: 1, resumes: 0, dueAt: 75 * hour },
      'pending:recent': { attempt: 1, resumes: 0, dueAt: 99 * hour },
      'unrelated': 'kept',
    },
  })

  await $.session.start(sessionStart)

  expect(Object.keys(world.store).sort()).toEqual(['pending:recent', 'unrelated'])
})

test('any other session end stops the timer but keeps the record for a restart', async ($, on) => {
  const world = createWorld(on)
  await $.turn.complete(errorTurn)

  await $.session.end({ reason: 'other', sessionId: 's1' } as Parameters<typeof $.session.end>[0])
  await world.clock.advance(10 * 60_000)

  expect(world.probes).toHaveLength(0)
  expect(world.store['pending:s1']).toEqual({ attempt: 1, resumes: 0, dueAt: 30_000 })
})

test('the pending record is stored before the resume is submitted', async ($, on) => {
  const world = createWorld(on)

  await $.turn.complete(errorTurn)
  await world.clock.advance(30_000)

  expect(world.pendingAtSubmit).toEqual([{ attempt: 2, resumes: 1, dueAt: 30_000 + 60_000 }])
})

test('a person prompt typed while the probe is in flight stops the resume', async ($, on) => {
  const world = createWorld(on)
  world.probeDelayMs = 5_000

  await $.turn.complete(errorTurn)
  await world.clock.advance(30_000)
  expect(world.probes).toHaveLength(1)

  await world.clock.advance(1_000)
  await $.prompt.submit({ text: 'never mind', wait: false, origin: { kind: 'composer' } })
  await world.clock.advance(10_000)

  expect(world.submits.map(s => s.text)).toEqual(['never mind'])
  expect(world.toasts).toEqual(['API unreachable. Retry 1 of 20.'])
  expect(world.store['pending:s1']).toBeUndefined()
})

test('an answer on the last retry keeps the resume count for the next failure', async ($, on) => {
  const world = createWorld(on, {
    now: 10_000,
    store: { 'pending:s1': { attempt: 20, resumes: 2, dueAt: 5_000 } },
  })

  await $.session.start(sessionStart)
  await world.clock.settle()
  expect(world.submits.map(s => s.text)).toEqual(['continue'])
  expect(world.store['pending:s1']).toEqual({ attempt: 20, resumes: 3, dueAt: 10_000 + 300_000 })

  await $.turn.complete(errorTurn)
  await world.clock.advance(60 * 60_000)

  expect(world.toasts.at(-1)).toBe('Resumed 3 times and the turn still failed. Not resuming.')
  expect(world.probes).toHaveLength(1)
  expect(world.store['pending:s1']).toBeUndefined()
})

const notAnOutage = [
  { role: 'assistant', text: 'Tool failed: permission denied', toolUses: [] },
  { role: 'user', text: 'API Error: pasted by the person', toolUses: [] },
] as const

for (const lastMessage of notAnOutage) {
  test(`an error turn whose last message (${lastMessage.role}) is not an API error drops the pending resume`, async ($, on) => {
    const world = createWorld(on, {
      store: { 'pending:s1': { attempt: 2, resumes: 1, dueAt: 90_000 } },
    })
    world.lastMessage = { ...lastMessage, toolUses: [] }

    await $.turn.complete(errorTurn)
    await world.clock.advance(10 * 60_000)

    expect(world.probes).toHaveLength(0)
    expect(world.spawns).toHaveLength(0)
    expect(world.store['pending:s1']).toBeUndefined()
  })
}

test('a probe that throws backs off to the next attempt and keeps going', async ($, on) => {
  const world = createWorld(on)
  world.probeAnswer = call => {
    if (call === 1) {
      throw new Error('probe transport broke')
    }
    return ANSWERED
  }

  await $.turn.complete(errorTurn)
  await world.clock.advance(30_000)

  expect(world.submits).toHaveLength(0)
  expect(world.store['pending:s1']).toEqual({ attempt: 2, resumes: 0, dueAt: 90_000 })

  await world.clock.advance(60_000)
  expect(world.probes).toHaveLength(2)
  expect(world.submits.map(s => s.text)).toEqual(['continue'])
  expect(world.toasts).toEqual([
    'API unreachable. Retry 1 of 20.',
    'API unreachable. Retry 2 of 20.',
    'API is back. Resuming.',
  ])
})

const endSession = { reason: 'other', sessionId: 's1' } as const

for (const probe of ['answers', 'throws'] as const) {
  test(`a probe in flight that ${probe} after the session ends neither resumes nor re-arms`, async ($, on) => {
    const world = createWorld(on)
    world.probeDelayMs = 5_000
    world.probeAnswer = () => {
      if (probe === 'throws') {
        throw new Error('probe transport broke')
      }
      return ANSWERED
    }

    await $.turn.complete(errorTurn)
    await world.clock.advance(30_000)
    expect(world.probes).toHaveLength(1)

    await $.session.end(endSession as Parameters<typeof $.session.end>[0])
    world.sessionId = 's2'
    await world.clock.advance(10 * 60_000)

    expect(world.submits).toHaveLength(0)
    expect(world.probes).toHaveLength(1)
    expect(world.spawns).toHaveLength(1)
    expect(world.store['pending:s1']).toEqual({ attempt: 1, resumes: 0, dueAt: 30_000 })
  })
}

test('an attempt still in flight for the old session does not block the new one', async ($, on) => {
  const world = createWorld(on)
  world.probeDelayMs = 5_000

  await $.turn.complete(errorTurn)
  await world.clock.advance(30_000)
  expect(world.probes).toHaveLength(1)

  await $.session.end(endSession as Parameters<typeof $.session.end>[0])
  world.sessionId = 's2'
  world.store['pending:s2'] = { attempt: 2, resumes: 0, dueAt: 0 }
  await $.session.start(sessionStart)
  await world.clock.advance(10 * 60_000)

  expect(world.submits.map(s => s.text)).toEqual(['continue'])
  expect(world.probes).toHaveLength(2)
  expect(world.spawns).toHaveLength(2)
  expect(world.store['pending:s1']).toEqual({ attempt: 1, resumes: 0, dueAt: 30_000 })
  expect(world.store['pending:s2']).toEqual({ attempt: 3, resumes: 1, dueAt: 35_000 + 120_000 })
})

test('a person prompt that lands while the plugin reads the session id leaves no stray continue', async ($, on) => {
  const world = createWorld(on)
  // The second session.id of the attempt, the one after the probe, is the slow one.
  world.probeAnswer = () => {
    world.sessionIdDelayMs = 5_000
    return ANSWERED
  }

  await $.turn.complete(errorTurn)
  await world.clock.advance(30_000)
  expect(world.probes).toHaveLength(1)

  world.sessionIdDelayMs = 0
  await $.prompt.submit({ text: 'never mind', wait: false, origin: { kind: 'composer' } })
  await world.clock.advance(10 * 60_000)

  expect(world.submits.map(s => s.text)).toEqual(['never mind'])
  expect(world.store['pending:s1']).toBeUndefined()
})

test('a person prompt that lands while an error turn arms schedules no attempt and starts no watcher', async ($, on) => {
  const world = createWorld(on)
  world.sessionIdDelayMs = 5_000

  const turn = $.turn.complete(errorTurn)
  await world.clock.advance(5_000)
  expect(world.store['pending:s1']).toEqual({ attempt: 1, resumes: 0, dueAt: 35_000 })

  world.sessionIdDelayMs = 0
  await $.prompt.submit({ text: 'never mind', wait: false, origin: { kind: 'composer' } })
  await world.clock.advance(10 * 60_000)
  await turn

  expect(world.spawns).toHaveLength(0)
  expect(world.probes).toHaveLength(0)
  expect(world.submits.map(s => s.text)).toEqual(['never mind'])
  expect(world.store['pending:s1']).toBeUndefined()
})

test('a person prompt that lands while the plugin reads the record leaves no stray continue', async ($, on) => {
  const world = createWorld(on)
  // The store read after the probe is the slow one, so it answers with the record from before the prompt.
  world.probeAnswer = () => {
    world.storeGetDelayMs = 5_000
    return ANSWERED
  }

  await $.turn.complete(errorTurn)
  await world.clock.advance(30_000)
  expect(world.probes).toHaveLength(1)

  world.storeGetDelayMs = 0
  await $.prompt.submit({ text: 'never mind', wait: false, origin: { kind: 'composer' } })
  await world.clock.advance(10 * 60_000)

  expect(world.submits.map(s => s.text)).toEqual(['never mind'])
  expect(world.store['pending:s1']).toBeUndefined()
})

const entryDelays = [
  ['session id', 'sessionIdDelayMs'],
  ['record', 'storeGetDelayMs'],
] as const

for (const [read, delay] of entryDelays) {
  test(`a person prompt that lands while an error turn reads the ${read} arms nothing`, async ($, on) => {
    const world = createWorld(on)
    world[delay] = 5_000

    const turn = $.turn.complete(errorTurn)
    await world.clock.advance(1_000)

    world[delay] = 0
    await $.prompt.submit({ text: 'never mind', wait: false, origin: { kind: 'composer' } })
    await world.clock.advance(10 * 60_000)
    await turn

    expect(world.spawns).toHaveLength(0)
    expect(world.probes).toHaveLength(0)
    expect(world.submits.map(s => s.text)).toEqual(['never mind'])
    expect(world.store['pending:s1']).toBeUndefined()
  })
}

test('a person prompt that lands while a session start reads the record arms nothing', async ($, on) => {
  const world = createWorld(on, { store: { 'pending:s1': { attempt: 1, resumes: 0, dueAt: 0 } } })
  world.storeGetDelayMs = 5_000

  const start = $.session.start(sessionStart)
  await world.clock.advance(1_000)

  world.storeGetDelayMs = 0
  await $.prompt.submit({ text: 'never mind', wait: false, origin: { kind: 'composer' } })
  await world.clock.advance(10 * 60_000)
  await start

  expect(world.spawns).toHaveLength(0)
  expect(world.probes).toHaveLength(0)
  expect(world.submits.map(s => s.text)).toEqual(['never mind'])
  expect(world.store['pending:s1']).toBeUndefined()
})

test('a session end that lands while arm reads the session id schedules no attempt and starts no watcher', async ($, on) => {
  const world = createWorld(on)
  // Both session.id calls are slow: advancing 5s releases the hook's, so arm has stored the record and stalls in its own.
  world.sessionIdDelayMs = 5_000

  const turn = $.turn.complete(errorTurn)
  await world.clock.advance(5_000)

  await $.session.end(endSession as Parameters<typeof $.session.end>[0])
  world.sessionId = 's2'
  world.sessionIdDelayMs = 0
  await world.clock.advance(10 * 60_000)
  await turn

  expect(world.spawns).toHaveLength(0)
  expect(world.probes).toHaveLength(0)
  expect(world.store['pending:s1']).toEqual({ attempt: 1, resumes: 0, dueAt: 35_000 })
})

test('a session end that lands while the plugin reads the session id after a probe counts no resume', async ($, on) => {
  const world = createWorld(on)
  world.probeAnswer = () => {
    world.sessionIdDelayMs = 5_000
    return ANSWERED
  }

  await $.turn.complete(errorTurn)
  await world.clock.advance(30_000)
  expect(world.probes).toHaveLength(1)

  await $.session.end(endSession as Parameters<typeof $.session.end>[0])
  world.sessionId = 's2'
  world.sessionIdDelayMs = 0
  await world.clock.advance(10 * 60_000)

  expect(world.submits).toHaveLength(0)
  expect(world.store['pending:s1']).toEqual({ attempt: 1, resumes: 0, dueAt: 30_000 })
})

test('a person prompt that lands while the plugin stores the resume leaves no stray continue', async ($, on) => {
  const world = createWorld(on)
  // Only the write after the probe is slow, so the prompt lands between it and the submit.
  world.probeAnswer = () => {
    world.storeSetDelayMs = 5_000
    return ANSWERED
  }

  await $.turn.complete(errorTurn)
  await world.clock.advance(30_000)
  expect(world.probes).toHaveLength(1)

  world.storeSetDelayMs = 0
  await $.prompt.submit({ text: 'never mind', wait: false, origin: { kind: 'composer' } })
  await world.clock.advance(10 * 60_000)

  expect(world.submits.map(s => s.text)).toEqual(['never mind'])
  expect(world.store['pending:s1']).toBeUndefined()
})

test('a second error turn after an answered probe backs off from attempt 2', async ($, on) => {
  const world = createWorld(on)

  await $.turn.complete(errorTurn)
  await world.clock.advance(30_000)
  await $.turn.complete(errorTurn)

  expect(world.store['pending:s1']).toEqual({ attempt: 2, resumes: 1, dueAt: 90_000 })

  await world.clock.advance(59_999)
  expect(world.probes).toHaveLength(1)

  await world.clock.advance(1)
  expect(world.probes).toHaveLength(2)
  expect(world.toasts).toEqual([
    'API unreachable. Retry 1 of 20.',
    'API is back. Resuming.',
    'API unreachable. Retry 2 of 20.',
    'API is back. Resuming.',
  ])
})

const unreadable: [string, unknown][] = [
  ['a string', 'garbage'],
  ['null', null],
  ['attempt 0', { attempt: 0, resumes: 0, dueAt: 0 }],
  ['attempt 21', { attempt: 21, resumes: 0, dueAt: 0 }],
  ['attempt 1.5', { attempt: 1.5, resumes: 0, dueAt: 0 }],
  ['resumes -1', { attempt: 1, resumes: -1, dueAt: 0 }],
  ['dueAt -Infinity', { attempt: 1, resumes: 0, dueAt: -Infinity }],
]

for (const [label, seeded] of unreadable) {
  test(`a stored record that is ${label} is ignored and the next error starts over`, async ($, on) => {
    const world = createWorld(on, { now: 1_000, store: { 'pending:s1': seeded } })

    await $.session.start(sessionStart)
    await world.clock.advance(10 * 60_000)
    expect(world.probes).toHaveLength(0)
    expect(world.spawns).toHaveLength(0)

    await $.turn.complete(errorTurn)

    expect(world.store['pending:s1']).toEqual({
      attempt: 1,
      resumes: 0,
      dueAt: 1_000 + 10 * 60_000 + 30_000,
    })
  })
}

test('a probe aborted before it answered counts as a failed attempt', async ($, on) => {
  const world = createWorld(on)
  world.probeAnswer = () =>
    ({ isAnswered: false, reason: 'aborted', usage: ANSWERED.usage }) as ModelCompleteResult

  await $.turn.complete(errorTurn)
  await world.clock.advance(30_000)

  expect(world.submits).toHaveLength(0)
  expect(world.store['pending:s1']).toEqual({ attempt: 2, resumes: 0, dueAt: 90_000 })
})
