# React effects — you might not need an Effect
Grounded in react.dev — [You Might Not Need an Effect](https://react.dev/learn/you-might-not-need-an-effect).

Default stance: an Effect is probably wrong. Effects are an escape hatch for
**synchronizing with an external system** (network, DOM, non-React widget). No
external system involved → no Effect. Use one only for code that must run
*because the component was displayed*. Caused by an interaction → event handler.
Producible from props/state → calculate it. Empty/omitted deps faking "run once"
= smell.

Anti-patterns → fix (react.dev section names):
- Updating state from props/state → calculate during render, don't mirror to state.
- Caching expensive calculations → `useMemo(fn, deps)` (only if measurably
  expensive per `console.time`; rarely is).
- Resetting all state on a prop change → pass a different `key` to remount.
- Adjusting some state on a prop change → calculate during render (store an id,
  `find` the object); no Effect.
- Sharing logic between event handlers → extract a shared function.
- Sending a POST → interaction-driven POST goes in the handler; only
  display-driven POST (e.g. analytics `visit_form`) stays in an Effect.
- Chains of computations → calculate in render + do all next-state updates in the
  one handler that started it.
- Initializing the application → module scope or entry point (`App.js`), not a
  component Effect.
- Notifying parent about state changes → update both in the same event, or lift
  state up (controlled). "Whenever you try to keep two different state variables
  synchronized, try lifting state up instead."
- Passing data to the parent → parent fetches, passes down.
- Subscribing to an external store → `useSyncExternalStore`, not manual
  `addEventListener` + state in an Effect.

Legit Effects — syncing with something outside React:
- Fetching data — **with a cleanup/ignore flag** for race conditions; prefer a
  framework's fetching, a cache lib, or a custom Hook over raw `useEffect`.
- Imperative DOM not expressible in render (`el.play()`, `dialog.showModal()`).
- Subscribing to browser/3rd-party APIs, legacy widgets.
- Connecting to an external server/store (chat connect/disconnect in cleanup).
- Timers/intervals tied to the component being on screen.
- Display-driven analytics logging (not tied to a click).
