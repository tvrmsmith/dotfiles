// Pure reading of the two load signals. The `$.process.run` calls that
// produce the text live in register.ts: the engine follows `$` only into
// functions of the file that registers the hooks.

const MIN_FREE_MEMORY = 20
const MIN_IDLE_CPU = 10

// One reading of a signal: the number as the tool printed it, or undefined
// when the tool failed or printed nothing that parses.
type Signal = string | undefined

export type Load = { memory: Signal; cpu: Signal }

// A signal that cannot be read counts as healthy, so a missing tool never
// holds anything.
const below = (signal: Signal, min: number) => signal !== undefined && Number(signal) < min

export const isBusy = (load: Load): boolean =>
  below(load.memory, MIN_FREE_MEMORY) || below(load.cpu, MIN_IDLE_CPU)

export const describeLoad = (load: Load): string =>
  `memory ${load.memory ?? '?'}% free, CPU ${load.cpu ?? '?'}% idle`

// "System-wide memory free percentage: 46%" -> "46"
export const parseFreeMemory = (stdout: string): Signal =>
  /free percentage:\s*([\d.]+)%/.exec(stdout)?.[1]

// The second sample of `top`, since the first averages since boot.
// "CPU usage: 38.47% user, 24.34% sys, 37.17% idle" -> "37.17"
export const parseIdleCpu = (stdout: string): Signal => {
  const samples = stdout.split('\n').filter(line => line.includes('CPU usage'))
  return /([\d.]+)% idle/.exec(samples.at(-1) ?? '')?.[1]
}
