export type Pending = {
  command: string
  ghLine: string
  agent: 'checking' | 'answers' | 'not answering'
  isRetrying: boolean
}

declare module 'claude-code' {
  interface PluginState {
    '1p-retry-band': { pending: Pending | null }
  }
}
