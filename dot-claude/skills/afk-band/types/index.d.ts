export type Afk = { until: number; label: string; parked: number }

declare module 'claude-code' {
  interface PluginState {
    'afk-band': { armed: Afk | null }
  }
}
