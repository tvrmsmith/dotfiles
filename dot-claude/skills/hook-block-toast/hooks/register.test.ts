import { expect, test } from 'claude-code/testing'
import type { Engine } from 'claude-code/testing'
import type { On } from 'claude-code'

// mock.store answers $.store from memory the test cannot read back, so this
// fake keeps the entries where the test can see them.
const fakeStore = (on: On, entries: Record<string, unknown> = {}) => {
  const held = new Map(Object.entries(entries))
  on('store.get', (_$, e) => ({ value: held.get(e.key) }))
  on('store.set', (_$, e) => {
    held.set(e.key, e.value)

    return { value: undefined }
  })
  on('store.keys', () => ({ value: [...held.keys()] }))

  return held
}

const collectToasts = (on: On) => {
  const toasts: string[] = []
  on('ui.toast', (_$, e) => {
    toasts.push(e.text)

    return { value: undefined }
  })

  return toasts
}

const AFK_REASON =
  'Trevor is AFK and will not see this question. Decide, log, park: take the'

test('a blocked Bash call toasts the hook name and first reason line, and counts it', async ($, on) => {
  const store = fakeStore(on)
  const toasts = collectToasts(on)
  const answer = {
    result: undefined,
    isError: true as const,
    text: `PreToolUse:Bash hook error: [$HOME/.claude/hooks/afk-guard.sh]: ${AFK_REASON}\nreversible option, log it as a decision with its reason.\n`,
  }
  on('tool.call', () => answer)

  const ran = await $.tool.call({ tool: 'Bash', command: 'ls' })

  expect(ran).toEqual(answer)
  expect(toasts).toEqual([`afk-guard.sh blocked Bash: ${AFK_REASON}`])
  expect(store.get('blocks:afk-guard.sh')).toBe(1)
})

test('a block adds to the count the store already holds', async ($, on) => {
  const store = fakeStore(on, { 'blocks:afk-guard.sh': 2 })
  collectToasts(on)
  on('tool.call', () => ({
    result: undefined,
    isError: true,
    text: `PreToolUse:Bash hook error: [$HOME/.claude/hooks/afk-guard.sh]: ${AFK_REASON}\n`,
  }))

  await $.tool.call({ tool: 'Bash', command: 'ls' })

  expect(store.get('blocks:afk-guard.sh')).toBe(3)
})

test('a block with no bracketed command is the unnamed hook, and the toast keeps only the first reason line', async ($, on) => {
  const store = fakeStore(on)
  const toasts = collectToasts(on)
  on('tool.call', () => ({
    result: undefined,
    isError: true,
    text: 'PreToolUse:Edit hook error: adr-guard: ADRs are append-only\nsecond line',
  }))

  await $.tool.call({ tool: 'Edit', file_path: '/x', old_string: 'a', new_string: 'b' })

  expect(toasts).toEqual(['unnamed hook blocked Edit: adr-guard: ADRs are append-only'])
  expect(store.get('blocks:unnamed hook')).toBe(1)
})

test('a bracketed command that is not a path names itself', async ($, on) => {
  fakeStore(on)
  const toasts = collectToasts(on)
  on('tool.call', () => ({
    result: undefined,
    isError: true,
    text: 'PreToolUse:Bash hook error: [rtk hook claude]: rewrite failed',
  }))

  await $.tool.call({ tool: 'Bash', command: 'ls' })

  expect(toasts).toEqual(['rtk hook claude blocked Bash: rewrite failed'])
})

test('a bracketed command that is not a path is cut to its first 40 characters', async ($, on) => {
  const store = fakeStore(on)
  const toasts = collectToasts(on)
  on('tool.call', () => ({
    result: undefined,
    isError: true,
    text: 'PreToolUse:Bash hook error: [if [ -z "${HOME-}" ]; then case "${OSTYPE-}" in msys*) exit 0 ;; esac; fi]: nope',
  }))

  await $.tool.call({ tool: 'Bash', command: 'ls' })

  expect(toasts).toEqual(['if [ -z "${HOME-}" ]; then case "${OSTYP blocked Bash: nope'])
  expect(store.get('blocks:if [ -z "${HOME-}" ]; then case "${OSTYP')).toBe(1)
})

test('an error that is not a hook block raises no toast and counts nothing', async ($, on) => {
  const store = fakeStore(on)
  const toasts = collectToasts(on)
  on('tool.call', () => ({
    result: undefined,
    isError: true,
    text: 'Error: command not found: frob',
  }))

  await $.tool.call({ tool: 'Bash', command: 'frob' })

  expect(toasts).toEqual([])
  expect([...store.keys()]).toEqual([])
})

test('a successful call raises no toast and counts nothing', async ($, on) => {
  const store = fakeStore(on)
  const toasts = collectToasts(on)
  on('tool.call', () => ({ result: 'hi', text: 'hi' }))

  await $.tool.call({ tool: 'Bash', command: 'echo hi' })

  expect(toasts).toEqual([])
  expect([...store.keys()]).toEqual([])
})

test('a bracketed command led by a bare program names itself even when a later argument is a path', async ($, on) => {
  fakeStore(on)
  const toasts = collectToasts(on)
  on('tool.call', () => ({
    result: undefined,
    isError: true,
    text: 'PreToolUse:Bash hook error: [python3 /opt/hooks/guard.py]: nope',
  }))

  await $.tool.call({ tool: 'Bash', command: 'ls' })

  expect(toasts).toEqual(['python3 /opt/hooks/guard.py blocked Bash: nope'])
})

test('a successful call whose output reads like a block raises no toast and counts nothing', async ($, on) => {
  const store = fakeStore(on)
  const toasts = collectToasts(on)
  const text = 'PreToolUse:Bash hook error: [$HOME/.claude/hooks/afk-guard.sh]: from a log file'
  on('tool.call', () => ({ result: text, text }))

  await $.tool.call({ tool: 'Bash', command: 'cat hooks.log' })

  expect(toasts).toEqual([])
  expect([...store.keys()]).toEqual([])
})

test('an error that quotes a block past its first character raises no toast and counts nothing', async ($, on) => {
  const store = fakeStore(on)
  const toasts = collectToasts(on)
  on('tool.call', () => ({
    result: undefined,
    isError: true,
    text: 'Exit code 1\nPreToolUse:Bash hook error: [$HOME/.claude/hooks/afk-guard.sh]: quoted',
  }))

  await $.tool.call({ tool: 'Bash', command: 'grep -r hook error' })

  expect(toasts).toEqual([])
  expect([...store.keys()]).toEqual([])
})

const runHookBlocks = async ($: Engine, on: On) => {
  on('command.register', () => ({ value: { command: 'hook-blocks' } }))
  on('session.start', () => ({ cwd: '/tmp' }))
  await $.session.start({ cwd: '/tmp', surface: 'terminal', isInteractive: true })

  return $.command.run({
    command: 'hook-blocks',
    args: '',
    origin: { kind: 'composer' },
    presentation: { isFullscreen: false, columns: 80 },
  })
}

test('/hook-blocks lists blocks per hook, highest first, ties by name', async ($, on) => {
  fakeStore(on, {
    'blocks:afk-guard.sh': 3,
    'blocks:unnamed hook': 5,
    'blocks:load-gate.sh': 3,
    'other-key': 9,
  })

  const ran = await runHookBlocks($, on)

  expect(ran.text).toBe('unnamed hook  5\nafk-guard.sh  3\nload-gate.sh  3')
})

test('/hook-blocks says so when no block was recorded', async ($, on) => {
  fakeStore(on)

  const ran = await runHookBlocks($, on)

  expect(ran.text).toBe('No hook blocks recorded.')
})
