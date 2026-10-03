import { atom, read, update } from 'claude-code'
import type { EngineInterface as Engine, Register, Timer } from 'claude-code'

import type { Pending } from '../types'

const BANNER = 'gh: needs write access, asking 1Password to approve:'
const pending = atom({ plugin: '1p-retry-band', key: 'pending' } as const, null)

const lastGhLine = (text: string): string | undefined => {
  const after = text.slice(text.lastIndexOf(BANNER) + BANNER.length)
  return after.split('\n').find(line => line.trim() !== '')?.trim()
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
  const shown = await read($, pending)
  if (!shown) return
  const command = shown.command

  // Claim the press inside the write, so a double press cannot both pass.
  let isClaimed = false
  await update($, pending, (p: Pending | null) => {
    isClaimed = p !== null && !p.isRetrying
    return p !== null && isClaimed ? { ...p, isRetrying: true } : p
  })
  if (!isClaimed) return

  const res = await $.tool.call({
    tool: 'Bash',
    command,
    consent: 'The user pressed "Retry" on the 1Password retry band',
  })
  const isOk = res.deny === undefined && res.isError !== true

  await update($, pending, (p: Pending | null) => {
    if (p === null || p.command !== command) return p
    return isOk ? null : { ...p, isRetrying: false }
  })

  const outcome = isOk ? 'It succeeded.' : 'It failed.'
  const text = `The person re-ran \`${command}\` from the 1Password retry band. ${outcome}\n\n${(res.deny ?? res.text ?? '').slice(0, 2000)}`
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
    if ((await read($, pending)) !== null && timer === undefined) startProbe($)
    return next(e)
  })

  on('tool.call', { tool: 'Bash' }, async ($, e, next) => {
    const ran = await next(e)

    if (ran.deny === undefined && ran.text?.includes(BANNER)) {
      if (ran.isError === true) {
        const timedOut: Pending = {
          command: e.command,
          ghLine: lastGhLine(ran.text) ?? e.command,
          agent: 'checking',
          isRetrying: false,
        }
        await update($, pending, () => timedOut).catch(() => undefined)
        startProbe($)
      } else {
        await update($, pending, (p: Pending | null) => (p?.command === e.command ? null : p)).catch(() => undefined)
      }
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
            <Text>r re-runs: {shown.command.slice(0, 120)}</Text>
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
