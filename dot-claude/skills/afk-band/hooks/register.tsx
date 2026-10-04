import { atom, read, update } from 'claude-code'
import type { Hook, Register, Timer } from 'claude-code'

import type { Afk } from '../types'

type Api = Parameters<Hook<'session.start'>>[0]

const POLL_MS = 15_000

const armed = atom({ plugin: 'afk-band', key: 'armed' } as const, null as Afk | null)

let deadline: Timer | null = null
let poll: Timer | null = null
let isInteractive = false
let queue: Promise<unknown> = Promise.resolve()

async function refresh($: Api) {
  const home = await $.env.get('HOME')
  const flagPath = `${home}/.claude/afk`
  const previous = await read($, armed)
  const now = await $.clock.now()

  const flag = await $.fs.read(flagPath).catch(() => null)
  const first = flag === null ? '' : (String(flag).split('\n')[0] ?? '')
  const until = Number(first.replace(/\D/g, ''))

  if (flag !== null && until * 1000 <= now) {
    const removed = await $.process.run(['rm', '-f', flagPath])
    if (removed.exitCode !== 0) return
  }

  deadline?.cancel()
  deadline = null

  if (flag === null || until * 1000 <= now) {
    if (previous !== null) {
      await update($, armed, () => null)
      if (previous.until * 1000 <= now) $.ui.toast('AFK ended')
    }
    return
  }

  deadline = $.clock.after(until * 1000 - now, () => refreshQuietly($))

  const label = previous?.until === until ? previous.label : await returnTime($, until)
  const sessionId = await $.session.id()
  const stateHome = (await $.env.get('XDG_STATE_HOME')) || `${home}/.local/state`
  const log = await $.fs
    .read(`${stateHome}/agent-decision-logs/afk-${sessionId}.tsv`)
    .catch(() => '')
  const parked = String(log)
    .split('\n')
    .filter(line => (line.split('\t')[5] ?? '').startsWith('parked')).length

  if (previous?.until !== until || previous.label !== label || previous.parked !== parked) {
    await update($, armed, () => ({ until, label, parked }))
  }
}

// The host formats the time, in afk-arm.sh's own words, so the plugin
// environment's time zone never enters into it.
async function returnTime($: Api, until: number) {
  const { exitCode, stdout } = await $.process.run(['date', '-r', String(until), '+%a %-d %b %H:%M'])
  if (exitCode !== 0) throw new Error(`date exited ${exitCode}`)
  return stdout.trim()
}

// Each refresh waits for the one before, so a poll landing on the deadline
// sees what the timer already cleared and toasts nothing more. A failed
// refresh only logs: a timer callback has nobody to reject to, and the next
// poll tries again.
function refreshQuietly($: Api) {
  queue = queue
    .then(() => refresh($))
    .catch(error => $.ui.log(`afk-band refresh failed: ${error}`, { to: 'debug' }))
  return queue
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    isInteractive = e.isInteractive
    poll?.cancel()
    poll = null
    if (isInteractive) {
      poll = $.clock.every(POLL_MS, () => refreshQuietly($))
      await refreshQuietly($)
    }
    return next(e)
  })

  // afk-guard.sh arms or clears AFK on /afk and blocks the expansion, and the
  // block lands as a notice made after the flag was written. The expansion
  // event itself is no use here: a managed plugin can send it past the user tier.
  on('session.append', { door: 'notice' }, async ($, e, next) => {
    if (isInteractive) await refreshQuietly($)
    return next(e)
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const afk = await read($, armed)
    if (e.props.hasSurvey || afk === null) return next(e)

    const { Text } = $.ui.resolve(e)
    return <Text>AFK until {afk.label} · {afk.parked} parked</Text>
  })
}
