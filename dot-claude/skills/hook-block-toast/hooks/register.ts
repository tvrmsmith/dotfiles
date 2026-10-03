import type { Register } from 'claude-code'

const BLOCK = /^PreToolUse:(\S+) hook error: (?:\[(.+?)\]: )?(.*)/s

type Block = { tool: string; name: string; reason: string }

const COUNT_PREFIX = 'blocks:'
const NO_BLOCKS = 'No hook blocks recorded.'
const COMMAND_NAME_LENGTH = 40
const UNNAMED = 'unnamed hook'

const hookName = (command: string | undefined): string => {
  if (command === undefined) return UNNAMED

  const program = command.split(/\s+/)[0]!
  if (program.includes('/')) return program.split('/').pop()!

  return command.slice(0, COMMAND_NAME_LENGTH)
}

const parseBlock = (text: string): Block | undefined => {
  const match = BLOCK.exec(text)
  if (!match) return undefined
  const [, tool, command, rest] = match

  return { tool: tool!, name: hookName(command), reason: rest!.split('\n')[0]! }
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    await $.command.register({
      name: 'hook-blocks',
      description: 'List how often each settings hook blocked a tool call',
    })

    return next(e)
  })

  on('command.run', { command: 'hook-blocks' }, async $ => {
    const counts: Array<{ name: string; count: number }> = []
    for (const key of await $.store.keys()) {
      if (key.startsWith(COUNT_PREFIX)) {
        counts.push({ name: key.slice(COUNT_PREFIX.length), count: Number(await $.store.get(key)) })
      }
    }
    counts.sort((a, b) => b.count - a.count || (a.name < b.name ? -1 : 1))

    return { text: counts.map(c => `${c.name}  ${c.count}`).join('\n') || NO_BLOCKS }
  })

  on('tool.call', async ($, e, next) => {
    const ran = await next(e)
    const block = ran.isError === true && ran.text ? parseBlock(ran.text) : undefined
    if (block) {
      $.ui.toast(`${block.name} blocked ${block.tool}: ${block.reason}`)
      const key = `${COUNT_PREFIX}${block.name}`
      await $.store.set(key, Number((await $.store.get(key)) ?? 0) + 1)
    }

    return ran
  })
}
