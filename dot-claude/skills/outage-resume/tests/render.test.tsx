import { test } from 'claude-code/testing'

import { expect } from './harness'

const SURFACES = ['terminal', 'desktop'] as const
const PLUGIN_ORIGIN = { kind: 'plugin', name: 'outage-resume' } as const
const OTHER_PLUGIN_ORIGIN = { kind: 'plugin', name: 'someone-else' } as const

test('the resume prompt row draws as one dim line naming the outage', async ($, on) => {
  on('ui.render', { component: 'UserMessage' }, ($, e) => {
    const { Text } = $.ui.resolve(e)
    return <Text>{e.props.text}</Text>
  })

  for (const surface of SURFACES) {
    const ui = await $.ui.mount({
      plugin: 'outage-resume',
      surface,
      component: 'UserMessage',
      props: { text: 'continue', origin: PLUGIN_ORIGIN, isExpanded: false },
    })

    const line = await ui.find({ type: 'Text', text: /resumed after an API outage/ })
    expect(line?.text).toBe('↻ resumed after an API outage')
    expect(line?.props.dimColor).toBe(true)
    expect(await ui.findAll({ type: 'Text' })).toHaveLength(1)
  }
})

test('an expanded row, a typed row and another plugin row stand as the engine drew them', async ($, on) => {
  on('ui.render', { component: 'UserMessage' }, ($, e) => {
    const { Text } = $.ui.resolve(e)
    return <Text>{`engine: ${e.props.text}`}</Text>
  })
  const cases = [
    { origin: PLUGIN_ORIGIN, isExpanded: true },
    { origin: { kind: 'composer' }, isExpanded: false },
    { origin: OTHER_PLUGIN_ORIGIN, isExpanded: false },
  ] as const

  for (const surface of SURFACES) {
    for (const { origin, isExpanded } of cases) {
      const ui = await $.ui.mount({
        plugin: 'outage-resume',
        surface,
        component: 'UserMessage',
        props: { text: 'continue', origin, isExpanded },
      })

      expect((await ui.find({ type: 'Text' }))?.text).toBe('engine: continue')
    }
  }
})
