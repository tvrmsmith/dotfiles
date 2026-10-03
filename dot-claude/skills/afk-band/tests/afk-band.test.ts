import { expect, mock, test } from 'claude-code/testing'
import type { Engine } from 'claude-code/testing'
import type { On } from 'claude-code'

const NOW = 1791000000000
const FLAG = '/home/t/.claude/afk'
const LOG = '/home/t/.local/state/agent-decision-logs/afk-sess-1.tsv'
const T1 = 1791039600

const SURFACES = ['terminal', 'desktop'] as const

type World = {
  files: Map<string, string>
  toasts: string[]
  runs: string[][]
  rmExit: { code: number }
  dateExit: { code: number }
  clock: ReturnType<typeof mock.clock>
}

const world = (
  on: On,
  options: { files?: Record<string, string>; env?: Record<string, string> } = {},
): World => {
  const w: World = {
    files: new Map(Object.entries(options.files ?? {})),
    toasts: [],
    runs: [],
    rmExit: { code: 0 },
    dateExit: { code: 0 },
    clock: mock.clock(on, { now: NOW }),
  }
  mock.env(on, { HOME: '/home/t', ...options.env })

  on('session.start', (_$, e) => ({ cwd: e.cwd }))
  on('ui.render', () => ({ type: 'Box', props: {}, children: [] }))
  on('ui.log', () => ({ value: undefined }))
  on('session.id', () => ({ value: 'sess-1' }))
  on('fs.read', (_$, e) => {
    const text = w.files.get(e.path)
    return text === undefined ? { deny: 'ENOENT' } : { value: text }
  })
  on('ui.toast', (_$, e) => {
    w.toasts.push(e.text)
    return { value: undefined }
  })
  on('process.run', (_$, e) => {
    w.runs.push([...e.argv])
    if (e.argv[0] === 'date') {
      if (w.dateExit.code !== 0) return ran(w.dateExit.code, '', 'date: illegal time')
      return ran(0, `${DATES[e.argv[2] ?? '']}\n`)
    }
    if (e.argv[0] === 'rm' && w.rmExit.code === 0) w.files.delete(FLAG)
    return ran(w.rmExit.code)
  })
  return w
}

const ran = (exitCode: number, stdout = '', stderr = '') => ({
  value: { exitCode, stdout, stderr, isStdoutTruncated: false, isStderrTruncated: false },
})

const DATES: Record<string, string> = {
  '1791039600': 'Sat 3 Oct 10:00',
  '1791043200': 'Sat 3 Oct 11:00',
}

const bandText = async ($: Engine, surface: (typeof SURFACES)[number], hasSurvey = false) => {
  const band = await $.ui.mount({
    plugin: 'afk-band',
    surface,
    component: 'AbovePrompt',
    props: {
      hasSurvey,
      isWorking: false,
      maxRows: 10,
      bodyColumns: 80,
      scroll: { offset: 0, bodyRows: 10 },
      view: {},
    },
  })
  return (await band.find({ type: 'Text', text: 'AFK' }))?.text
}

const start = ($: Engine) =>
  $.session.start({ cwd: '/home/t', surface: 'terminal', isInteractive: true })

for (const surface of SURFACES) {
  test(`no flag, no band (${surface})`, async ($, on) => {
    world(on)
    await start($)
    expect(await bandText($, surface)).toBeUndefined()
  })
}

const row = (...cells: string[]) => cells.join('\t')
const LOG_TEXT = [
  row('ts', 'phase', 'decision', 'why', 'evidence', 'result'),
  row('2026-10-02T04:00:00Z', 'park', 'merge the PR', "merge is Trevor's", 'PR 12', 'parked'),
  row('2026-10-02T04:01:00Z', 'park', 'push branch', '1Password unattended', 'branch x', 'parked: 1Password unlock'),
  row('2026-10-02T04:02:00Z', 'implement', 'tests pass', 'ran suite', 'run 4', 'done'),
  row('2026-10-02T04:03:00Z', 'audit', 'note parked items', 'reviewing parked rows', 'row 2', 'open'),
].join('\n') + '\n'

const BAND_T1 = 'AFK until Sat 3 Oct 10:00 · 2 parked'

for (const surface of SURFACES) {
  test(`flag with log shows the band (${surface})`, async ($, on) => {
    world(on, { files: { [FLAG]: `${T1}\n`, [LOG]: LOG_TEXT } })
    await start($)
    expect(await bandText($, surface)).toBe(BAND_T1)
  })
}

for (const surface of SURFACES) {
  test(`flag without a log file counts 0 parked (${surface})`, async ($, on) => {
    world(on, { files: { [FLAG]: `${T1}\n` } })
    await start($)
    expect(await bandText($, surface)).toBe('AFK until Sat 3 Oct 10:00 · 0 parked')
  })

  test(`a survey holds the band, no AFK band (${surface})`, async ($, on) => {
    world(on, { files: { [FLAG]: `${T1}\n`, [LOG]: LOG_TEXT } })
    await start($)
    expect(await bandText($, surface, true)).toBeUndefined()
  })

  test(`notes after the first flag line are ignored (${surface})`, async ($, on) => {
    world(on, { files: { [FLAG]: `${T1}\nskip the deploy\n`, [LOG]: LOG_TEXT } })
    await start($)
    expect(await bandText($, surface)).toBe(BAND_T1)
  })

  test(`XDG_STATE_HOME moves the log (${surface})`, async ($, on) => {
    world(on, {
      env: { XDG_STATE_HOME: '/state' },
      files: {
        [FLAG]: `${T1}\n`,
        '/state/agent-decision-logs/afk-sess-1.tsv': LOG_TEXT,
      },
    })
    await start($)
    expect(await bandText($, surface)).toBe(BAND_T1)
  })
}

// What a session appends once afk-guard.sh has settled the flag and blocked
// the /afk expansion. The kit has nothing beneath session.append to store the
// row, and skips a test hook that answers it, so the call rejects once the
// plugin's hook has run; the band is what the test reads.
const guardNotice = ($: Engine, reason: string) =>
  $.session
    .append({
      door: 'notice',
      origin: { kind: 'hook', event: 'UserPromptExpansion' },
      uuid: 'notice-1',
      message: {
        type: 'system',
        content: [{ type: 'text', text: `UserPromptExpansion operation blocked by hook:\n${reason}` }],
      },
    })
    .catch(() => undefined)

for (const surface of SURFACES) {
  test(`arming with /afk shows the band at once (${surface})`, async ($, on) => {
    const w = world(on, { files: { [LOG]: LOG_TEXT } })
    await start($)
    expect(await bandText($, surface)).toBeUndefined()

    w.files.set(FLAG, `${T1}\n`)
    await guardNotice($, 'AFK on until Sat 3 Oct 10:00.')
    expect(await bandText($, surface)).toBe(BAND_T1)
  })
}

const RM = ['rm', '-f', FLAG]
const rmCalls = (w: World) => w.runs.filter(argv => argv[0] === 'rm')

for (const [name, flag] of [
  ['a stale flag', '1790999000\n'],
  ['a garbage first line', 'soon\n'],
] as const) {
  for (const surface of SURFACES) {
    test(`${name} at session start is removed quietly (${surface})`, async ($, on) => {
      const w = world(on, { files: { [FLAG]: flag, [LOG]: LOG_TEXT } })
      await start($)
      expect(rmCalls(w)).toEqual([RM])
      expect(w.toasts).toEqual([])
      expect(await bandText($, surface)).toBeUndefined()
    })
  }
}

const TO_T1 = 39_600_000
const ENDED = ['AFK ended']

for (const surface of SURFACES) {
  test(`the deadline clears the flag, toasts once, drops the band (${surface})`, async ($, on) => {
    const w = world(on, { files: { [FLAG]: `${T1}\n`, [LOG]: LOG_TEXT } })
    await start($)
    await w.clock.advance(TO_T1)
    expect(rmCalls(w)).toEqual([RM])
    expect(w.toasts).toEqual(ENDED)
    expect(await bandText($, surface)).toBeUndefined()
  })
}

for (const surface of SURFACES) {
  test(`/afk back clears the band without a toast (${surface})`, async ($, on) => {
    const w = world(on, { files: { [FLAG]: `${T1}\n`, [LOG]: LOG_TEXT } })
    await start($)
    expect(await bandText($, surface)).toBe(BAND_T1)

    w.files.delete(FLAG)
    await guardNotice($, 'AFK off.')
    expect(await bandText($, surface)).toBeUndefined()
    expect(w.toasts).toEqual([])

    await w.clock.advance(TO_T1 + 1000)
    expect(w.toasts).toEqual([])
    expect(rmCalls(w)).toEqual([])
  })
}

const POLL = 15_000
const T2 = 1791043200

for (const surface of SURFACES) {
  test(`another session arming shows up on the next poll (${surface})`, async ($, on) => {
    const w = world(on, { files: { [LOG]: LOG_TEXT } })
    await start($)
    expect(await bandText($, surface)).toBeUndefined()

    w.files.set(FLAG, `${T1}\n`)
    await w.clock.advance(POLL)
    expect(await bandText($, surface)).toBe(BAND_T1)
  })
}

for (const surface of SURFACES) {
  test(`another session re-arming later moves the deadline (${surface})`, async ($, on) => {
    const w = world(on, { files: { [FLAG]: `${T1}\n`, [LOG]: LOG_TEXT } })
    await start($)

    w.files.set(FLAG, `${T2}\n`)
    await w.clock.advance(POLL)
    expect(await bandText($, surface)).toBe('AFK until Sat 3 Oct 11:00 · 2 parked')

    await w.clock.advance(TO_T1 - POLL)
    expect(rmCalls(w)).toEqual([])
    expect(w.toasts).toEqual([])

    await w.clock.advance(3_600_000)
    expect(rmCalls(w)).toEqual([RM])
    expect(w.toasts).toEqual(ENDED)
  })

  test(`the parked count follows the log (${surface})`, async ($, on) => {
    const w = world(on, { files: { [FLAG]: `${T1}\n`, [LOG]: LOG_TEXT } })
    await start($)

    w.files.set(
      LOG,
      LOG_TEXT +
        row('2026-10-02T04:04:00Z', 'park', 'ship it', 'needs a decision', 'x', 'parked: Trevor decides') +
        '\n',
    )
    await w.clock.advance(POLL)
    expect(await bandText($, surface)).toBe('AFK until Sat 3 Oct 10:00 · 3 parked')
  })

  test(`a failed rm keeps the band and retries on the next poll (${surface})`, async ($, on) => {
    const w = world(on, { files: { [FLAG]: `${T1}\n`, [LOG]: LOG_TEXT } })
    w.rmExit.code = 1
    await start($)

    await w.clock.advance(TO_T1)
    expect(w.toasts).toEqual([])
    expect(await bandText($, surface)).toBe(BAND_T1)

    w.rmExit.code = 0
    await w.clock.advance(POLL)
    expect(w.toasts).toEqual(ENDED)
    expect(await bandText($, surface)).toBeUndefined()
  })
}

for (const surface of SURFACES) {
  test(`a failed date draws no band and retries on the next poll (${surface})`, async ($, on) => {
    const w = world(on, { files: { [FLAG]: `${T1}\n`, [LOG]: LOG_TEXT } })
    w.dateExit.code = 1
    await start($)
    expect(await bandText($, surface)).toBeUndefined()

    w.dateExit.code = 0
    await w.clock.advance(POLL)
    expect(await bandText($, surface)).toBe(BAND_T1)
  })
}

test('headless sessions start no timers', async ($, on) => {
  const w = world(on, { files: { [FLAG]: `${T1}\n`, [LOG]: LOG_TEXT } })
  await $.session.start({ cwd: '/home/t', surface: null, isInteractive: false })

  await w.clock.advance(TO_T1 + POLL)
  expect(rmCalls(w)).toEqual([])
  expect(w.toasts).toEqual([])
})
