import { expect, mock, test } from 'claude-code/testing'
import type { Engine } from 'claude-code/testing'
import type { On } from 'claude-code'

const PLUGIN = '1p-retry-band'
const BANNER = 'gh: needs write access, asking 1Password to approve:'

const COMPOUND = 'cd ~/dev/personal/dotfiles && gh pr merge --auto --squash 12'
const ERRORED = [
  BANNER,
  '    gh pr merge --auto --squash 12',
  '[ERROR] 2026/10/02 09:14:03 authorization timeout',
  'gh: could not read the write token for my.1password.com from 1Password.',
].join('\n')

const bash = { stdout: '', stderr: '', interrupted: false }
const SURFACES = ['terminal', 'desktop'] as const

type Answer = { text: string; isError?: true } | { deny: string } | { throws: string }

// The world beneath the plugin: the engine's Bash answers from `bashAnswers` in
// order (the last repeats), its probe answers `probe`, and the test records what
// the plugin sent to Bash, the toast and the session.
const engine = (on: On, bashAnswers: Answer[]) => {
  const world = {
    commands: [] as string[],
    toasts: [] as string[],
    probeArgvs: [] as (readonly string[])[],
    probe: (): { exitCode: number } => ({ exitCode: 2 }),
  }
  on('tool.call', { tool: 'Bash' }, (_$, e) => {
    const answer = bashAnswers[Math.min(world.commands.length, bashAnswers.length - 1)]!
    world.commands.push(e.command)
    if ('throws' in answer) throw new Error(answer.throws)
    return 'deny' in answer ? answer : { result: bash, ...answer }
  })
  on('process.run', (_$, e) => {
    world.probeArgvs.push(e.argv)
    return {
      value: { stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false, ...world.probe() },
    }
  })
  on('ui.render', { component: 'AbovePrompt' }, () => ({ type: 'Box', props: {}, children: [] }))
  on('ui.toast', (_$, e) => {
    world.toasts.push(e.text)
    return { value: undefined }
  })
  return Object.assign(world, { clock: mock.clock(on) })
}

type Surface = (typeof SURFACES)[number]

const mountBand = ($: Engine, surface: Surface) =>
  $.ui.mount({
    plugin: PLUGIN,
    surface,
    component: 'AbovePrompt',
    props: { hasSurvey: false, isWorking: false, maxRows: 20, columns: 100 } as never,
  })

test('a timed-out gh shows the band', async ($, on) => {
  engine(on, [{ text: ERRORED, isError: true }])

  await $.tool.call({ tool: 'Bash', command: COMPOUND })

  for (const surface of SURFACES) {
    const ui = await mountBand($, surface)
    expect((await ui.find({ key: 'waiting' }))?.text).toBe(
      'gh is waiting on 1Password: gh pr merge --auto --squash 12',
    )
    expect((await ui.find({ key: 'runs' }))?.text).toBe(`r re-runs: ${COMPOUND}`)
    expect(await ui.find({ key: 'retry' })).toBeDefined()
    await ui.unmount()
  }
})

const SUCCEEDED = [
  BANNER,
  '    gh pr merge --auto --squash 12',
  '✓ Pull request #12 will be automatically merged via squash when all requirements are met',
].join('\n')

const TWO_BANNERS = [
  BANNER,
  '    gh label create triage',
  BANNER,
  '    gh pr merge --auto 7',
  'gh: could not read the write token for my.1password.com from 1Password.',
].join('\n')

const SINGLE_7 = [BANNER, '    gh pr merge --auto 7', 'gh: could not read the write token for my.1password.com from 1Password.'].join('\n')

test('the plugin hands the model the tool result unchanged', async ($, on) => {
  engine(on, [{ text: ERRORED, isError: true }])

  const ran = await $.tool.call({ tool: 'Bash', command: COMPOUND })

  expect(ran.text).toBe(ERRORED)
  expect(ran.isError).toBe(true)
})

test('an errored result without the banner shows no band', async ($, on) => {
  engine(on, [{ text: 'fatal: not a git repository', isError: true }])

  await $.tool.call({ tool: 'Bash', command: 'git status' })

  for (const surface of SURFACES) {
    const ui = await mountBand($, surface)
    expect(await ui.find({ key: 'retry' })).toBeUndefined()
    await ui.unmount()
  }
})

test('an errored result whose banner is followed by gh output and a failing later step shows no band', async ($, on) => {
  const approvedThenFailed = [
    BANNER,
    '    gh issue create -t x -b y',
    'https://github.com/tvrmsmith/dotfiles/issues/99',
    'npm ERR! Test failed.  See above for more details.',
  ].join('\n')
  engine(on, [{ text: approvedThenFailed, isError: true }])

  await $.tool.call({ tool: 'Bash', command: 'gh issue create -t x -b y && npm test' })

  for (const surface of SURFACES) {
    const ui = await mountBand($, surface)
    expect(await ui.find({ key: 'retry' })).toBeUndefined()
    await ui.unmount()
  }
})

test('a successful result carrying the banner shows no band', async ($, on) => {
  engine(on, [{ text: SUCCEEDED }])

  await $.tool.call({ tool: 'Bash', command: COMPOUND })

  for (const surface of SURFACES) {
    const ui = await mountBand($, surface)
    expect(await ui.find({ key: 'retry' })).toBeUndefined()
    await ui.unmount()
  }
})

test('with two banners the band names the last gh line', async ($, on) => {
  engine(on, [{ text: TWO_BANNERS, isError: true }])

  await $.tool.call({ tool: 'Bash', command: 'gh label create triage && gh pr merge --auto 7' })

  for (const surface of SURFACES) {
    const ui = await mountBand($, surface)
    expect((await ui.find({ key: 'waiting' }))?.text).toBe('gh is waiting on 1Password: gh pr merge --auto 7')
    await ui.unmount()
  }
})

test('no runs line when the command is the gh line', async ($, on) => {
  engine(on, [{ text: SINGLE_7, isError: true }])

  await $.tool.call({ tool: 'Bash', command: 'gh pr merge --auto 7' })

  for (const surface of SURFACES) {
    const ui = await mountBand($, surface)
    expect(await ui.find({ key: 'waiting' })).toBeDefined()
    expect(await ui.find({ key: 'runs' })).toBeUndefined()
    await ui.unmount()
  }
})

// Each body runs once per surface, in a fresh test.
const onEachSurface = (name: string, body: ($: Engine, on: On, surface: Surface) => Promise<void>) => {
  for (const surface of SURFACES) {
    test(`${name} (${surface})`, ($, on) => body($, on, surface))
  }
}

// The kit cannot show the session note a retry appends: a plugin's own
// $.session.append never reaches the test's (or an inline plugin's)
// session.append hook, and the kit's bottom rejects it. This test holds what
// the kit can show, that the press settles and the band follows the outcome
// even though the append rejects.
onEachSurface('retry re-runs the whole command and clears the band on success', async ($, on, surface) => {
  const world = engine(on, [{ text: ERRORED, isError: true }, { text: SUCCEEDED }])
  await $.tool.call({ tool: 'Bash', command: COMPOUND })
  const ui = await mountBand($, surface)

  await ui.press({ key: 'retry' })

  expect(world.commands[1]).toBe(COMPOUND)
  expect(await ui.find({ key: 'retry' })).toBeUndefined()
})

onEachSurface('a retry that errors again keeps the band and retries again', async ($, on, surface) => {
  const world = engine(on, [{ text: ERRORED, isError: true }])
  await $.tool.call({ tool: 'Bash', command: COMPOUND })
  const ui = await mountBand($, surface)

  await ui.press({ key: 'retry' })
  expect(await ui.find({ key: 'retry' })).toBeDefined()
  await ui.press({ key: 'retry' })

  expect(world.commands).toEqual([COMPOUND, COMPOUND, COMPOUND])
})

onEachSurface('a denied retry keeps the band and retries again', async ($, on, surface) => {
  const world = engine(on, [{ text: ERRORED, isError: true }, { deny: 'denied' }])
  await $.tool.call({ tool: 'Bash', command: COMPOUND })
  const ui = await mountBand($, surface)

  await ui.press({ key: 'retry' })
  expect(await ui.find({ key: 'retry' })).toBeDefined()
  await ui.press({ key: 'retry' })

  expect(world.commands).toEqual([COMPOUND, COMPOUND, COMPOUND])
})

onEachSurface('a retry whose call throws leaves the band able to retry again', async ($, on, surface) => {
  const world = engine(on, [{ text: ERRORED, isError: true }, { throws: 'tool call failed' }, { text: SUCCEEDED }])
  await $.tool.call({ tool: 'Bash', command: COMPOUND })
  const ui = await mountBand($, surface)

  await ui.press({ key: 'retry' }).catch(() => undefined)
  await ui.press({ key: 'retry' })

  expect(world.commands).toEqual([COMPOUND, COMPOUND, COMPOUND])
  expect(await ui.find({ key: 'retry' })).toBeUndefined()
})

onEachSurface('dismiss clears the band', async ($, on, surface) => {
  engine(on, [{ text: ERRORED, isError: true }])
  await $.tool.call({ tool: 'Bash', command: COMPOUND })
  const ui = await mountBand($, surface)

  await ui.press({ key: 'dismiss' })

  expect(await ui.find({ key: 'retry' })).toBeUndefined()
})

onEachSurface('the model retrying the same command successfully clears the band', async ($, on, surface) => {
  engine(on, [{ text: ERRORED, isError: true }, { text: SUCCEEDED }])
  await $.tool.call({ tool: 'Bash', command: COMPOUND })
  await $.tool.call({ tool: 'Bash', command: COMPOUND })
  const ui = await mountBand($, surface)

  expect(await ui.find({ key: 'retry' })).toBeUndefined()
})

const agentText = async (ui: Awaited<ReturnType<typeof mountBand>>) => (await ui.find({ key: 'agent' }))?.text
const GH_LINE = 'gh pr merge --auto --squash 12'

onEachSurface('the probe reads the agent and toasts once when it starts answering', async ($, on, surface) => {
  const world = engine(on, [{ text: ERRORED, isError: true }])
  world.probe = () => ({ exitCode: 2 })
  await $.tool.call({ tool: 'Bash', command: COMPOUND })
  await world.clock.settle()
  const ui = await mountBand($, surface)
  expect(await agentText(ui)).toBe('1Password agent: not answering')

  world.probe = () => ({ exitCode: 0 })
  await world.clock.advance(15000)

  expect(await agentText(ui)).toBe('1Password agent: answers')
  expect(world.toasts).toEqual([`1Password answers again. Press r on the band to retry: ${GH_LINE}`])
  expect(world.probeArgvs.every(argv => argv.join(' ') === 'ssh-add -l')).toBe(true)
})

onEachSurface('exit 1 reads as answering and a rejecting probe as not answering', async ($, on, surface) => {
  const world = engine(on, [{ text: ERRORED, isError: true }])
  world.probe = () => ({ exitCode: 1 })
  await $.tool.call({ tool: 'Bash', command: COMPOUND })
  await world.clock.settle()
  const ui = await mountBand($, surface)
  expect(await agentText(ui)).toBe('1Password agent: answers')

  world.probe = () => {
    throw new Error('spawn failed')
  }
  await world.clock.advance(15000)

  expect(await agentText(ui)).toBe('1Password agent: not answering')
})

onEachSurface('a first probe that answers at once fires no toast', async ($, on, surface) => {
  const world = engine(on, [{ text: ERRORED, isError: true }])
  world.probe = () => ({ exitCode: 0 })
  await $.tool.call({ tool: 'Bash', command: COMPOUND })
  await world.clock.settle()
  await world.clock.advance(15000)
  const ui = await mountBand($, surface)

  expect(await agentText(ui)).toBe('1Password agent: answers')
  expect(world.toasts).toEqual([])
})

onEachSurface('the probe stops once the band clears', async ($, on, surface) => {
  const world = engine(on, [{ text: ERRORED, isError: true }])
  await $.tool.call({ tool: 'Bash', command: COMPOUND })
  await world.clock.settle()
  const ui = await mountBand($, surface)
  await ui.press({ key: 'dismiss' })
  const before = world.probeArgvs.length
  expect(before).toBeGreaterThan(0)

  await world.clock.advance(30000)

  expect(world.probeArgvs.length).toBe(before)
})

onEachSurface('a pending band draws nothing while a survey is showing', async ($, on, surface) => {
  engine(on, [{ text: ERRORED, isError: true }])
  await $.tool.call({ tool: 'Bash', command: COMPOUND })
  const ui = await $.ui.mount({
    plugin: PLUGIN,
    surface,
    component: 'AbovePrompt',
    props: { hasSurvey: true, isWorking: false, maxRows: 20, columns: 100 } as never,
  })

  expect(await ui.find({ key: 'retry' })).toBeUndefined()
})

onEachSurface('two presses of retry started together re-run the command once', async ($, on, surface) => {
  const world = engine(on, [{ text: ERRORED, isError: true }, { text: SUCCEEDED }])
  await $.tool.call({ tool: 'Bash', command: COMPOUND })
  const ui = await mountBand($, surface)

  await Promise.all([ui.press({ key: 'retry' }), ui.press({ key: 'retry' })])

  expect(world.commands).toEqual([COMPOUND, COMPOUND])
})
