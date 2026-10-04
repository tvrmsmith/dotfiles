// Anchored to a command position (start of a line, or after ; & | ( ) and past
// any leading VAR=value assignments, so that echoing, grepping, or documenting a
// runner is not mistaken for running it. The `m` flag anchors `^` per line, as
// grep -E does.
const POSITION = String.raw`(^|[;&|(])\s*([A-Za-z_][A-Za-z0-9_]*=\S*\s+)*`
const PREFIX = String.raw`((npx|bunx|pnpm exec|yarn|uv run|bundle exec|python3? -m)\s+)?`
const RUNNER = String.raw`(dotnet test|go test|cargo (test|nextest)|(npm|pnpm|yarn|bun)( run)? test(:\S*)?|vitest|jest|pytest|bats|rspec|playwright test|make test|mix test)`

const TEST_RUN = new RegExp(String.raw`${POSITION}${PREFIX}${RUNNER}(\s|$)`, 'm')

export const isTestRun = (command: string): boolean => TEST_RUN.test(command)
