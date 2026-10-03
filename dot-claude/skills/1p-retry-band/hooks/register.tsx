import { atom, read, update } from 'claude-code'
import type { EngineInterface as Engine, Register, Timer } from 'claude-code'

import type { Pending } from '../types'

const BANNER = 'gh: needs write access, asking 1Password to approve:'
const pending = atom({ plugin: '1p-retry-band', key: 'pending' } as const, null)

// The shim's own failure line, op's error line, or the Bash tool's timeout notice.
const ONE_PASSWORD_FAILED = [/^gh: could not read the write token/, /^\[ERROR\]/, /timed out/i]

// The gh line after the last line that is the banner, and whether the first line
// after it shows 1Password failing: none (cut off while op waited) or a failure line.
// Any other line there is gh's own output, so the write went through.
const lastBanner = (text: string) => {
  const lines = text.split('\n')
  const at = lines.lastIndexOf(BANNER)
  if (at === -1) return undefined
  const next = lines.slice(at + 2).find(line => line.trim() !== '')?.trim()
  return {
    ghLine: lines[at + 1]?.trim(),
    isFailed: next === undefined || ONE_PASSWORD_FAILED.some(failed => failed.test(next)),
  }
}

const PROBE_EVERY_MS = 15_000

const probeAgent = async ($: Engine): Promise<Pending['agent']> => {
  try {
    const { exitCode } = await $.process.run(['ssh-add', '-l'], { timeoutMs: 5000 })
    // 1 is an agent with no keys, still reachable.
    return exitCode === 0 || exitCode === 1 ? 'answers' : 'not answering'
  } catch {
    return 'not answering'
  }
}

const retry = async ($: Engine) => {
  // Claim the press inside the write, so a double press cannot both pass.
  let command = ''
  let isClaimed = false
  await update($, pending, (p: Pending | null) => {
    isClaimed = p !== null && !p.isRetrying
    if (p === null || !isClaimed) return p
    command = p.command
    return { ...p, isRetrying: true }
  })
  if (!isClaimed) return

  let isOk = false
  let output = ''
  try {
    const res = await $.tool.call({
      tool: 'Bash',
      command,
      consent: 'The user pressed "Retry" on the 1Password retry band',
    })
    isOk = res.deny === undefined && res.isError !== true
    output = (res.deny ?? res.text ?? '').slice(0, 2000)
  } finally {
    await update($, pending, (p: Pending | null) => {
      if (p === null || p.command !== command) return p
      return isOk ? null : { ...p, isRetrying: false }
    })
  }

  const outcome = isOk ? 'It succeeded.' : 'It failed.'
  const text = `The person re-ran \`${command}\` from the 1Password retry band. ${outcome}\n\n${output}`
  await $.session.append({ message: { type: 'user', content: [{ type: 'text', text }] } }).catch(() => undefined)
}

let timer: Timer | undefined

const stopProbe = () => {
  timer?.cancel()
  timer = undefined
}

// One probe pass: reads the agent, records it, toasts on a move to 'answers'.
const probe = async ($: Engine) => {
  if ((await read($, pending)) === null) {
    stopProbe()
    return
  }

  const agent = await probeAgent($)
  let before: Pending['agent'] | undefined
  let ghLine = ''
  await update($, pending, (p: Pending | null) => {
    before = p?.agent
    ghLine = p?.ghLine ?? ''
    return p === null ? p : { ...p, agent }
  })

  if (before === 'not answering' && agent === 'answers') {
    $.ui.toast(`1Password answers again. Press r on the band to retry: ${ghLine}`)
  }
}

const startProbe = ($: Engine) => {
  stopProbe()
  probe($).catch(() => undefined)
  timer = $.clock.every(PROBE_EVERY_MS, () => {
    probe($).catch(() => undefined)
  })
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    if ((await read($, pending)) !== null) startProbe($)
    return next(e)
  })

  on('tool.call', { tool: 'Bash' }, async ($, e, next) => {
    const ran = await next(e)

    const banner = ran.deny === undefined && ran.text !== undefined ? lastBanner(ran.text) : undefined
    if (banner === undefined) return ran

    if (ran.isError !== true) {
      await update($, pending, (p: Pending | null) => (p?.command === e.command ? null : p)).catch(() => undefined)
      return ran
    }

    if (banner.isFailed) {
      const stuck: Pending = { command: e.command, ghLine: banner.ghLine || e.command, agent: 'checking', isRetrying: false }
      await update($, pending, () => stuck).catch(() => undefined)
      startProbe($)
    }

    return ran
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const shown = await read($, pending)

    if (e.props.hasSurvey || !shown) {
      return next(e)
    }

    const { Box, Button, Text } = $.ui.resolve(e)

    return (
      <Box flexDirection="column">
        <Box key="waiting">
          <Text>gh is waiting on 1Password: {shown.ghLine}</Text>
        </Box>
        {shown.command !== shown.ghLine && (
          <Box key="runs">
            <Text>r re-runs: {shown.command}</Text>
          </Box>
        )}
        <Box key="agent">
          <Text>1Password agent: {shown.agent}</Text>
        </Box>
        <Box>
          <Button key="retry" label="Retry" hotkey="r" onPress={() => retry($)} />
          <Button
            key="dismiss"
            label="Dismiss"
            hotkey="d"
            role="dismiss"
            onPress={() => update($, pending, () => null)}
          />
        </Box>
      </Box>
    )
  })
}
