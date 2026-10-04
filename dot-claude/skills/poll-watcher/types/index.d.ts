export type PollWatch = {
  command: string                      // the status command after the sleep
  cwd: string                          // where it runs; command + cwd is the identity
  intervalMs: number
  phase: 'watching' | 'changed' | 'stopped'  // watching: model waits; changed: model told,
                                             // still ticking quietly; stopped: timer gone
  output: string                       // stdout + stderr, trimmed, last 4,000 chars
  fingerprint: string                  // hash of the whole output, volatile tokens
                                       // masked, before the cut; what a tick compares
  exitCode: number
  armedAt: number                      // the model's last poll; also the stale-tick guard
  checkedAt: number
  changedAt: number
}
declare module 'claude-code' {
  interface PluginState { 'poll-watcher': { watches: PollWatch[] } }
}
