---
name: playwright-demo-video
description: Record a clean, human-watchable walkthrough video of a web app with Playwright. Use when asked to make a demo/walkthrough/screen-recording video of a feature or flow. Triggers on "demo video", "playwright video".
disable-model-invocation: true
---

# Playwright Demo Video

Record ONE continuous, narrated-by-captions walkthrough clip of a real running app — a clip a human watches, not failure forensics. Uses Playwright's native recording (>= 1.59 for in-video annotations), a custom caption overlay, and ffmpeg for a portable mp4.

**Prefer the dual-mode spec** (§2): ONE `*.spec.ts` that runs as a fast CI e2e gate by default AND, under a `DEMO=1` env flag flipped by the demo config, becomes the paced/captioned/recorded walkthrough. Same steps, same assertions — the demo can't drift from the tested behavior, and you maintain one file instead of two. A demo-only `*.demo.spec.ts` is the fallback when the flow isn't worth gating in CI (throwaway marketing clip, a flow the suite already covers elsewhere).

## 0. Prereqs

- **Playwright >= 1.59** for `video.show` (action highlights). Check: `pnpm exec playwright --version` (or `npx`). Below 1.59 → upgrade (`pnpm add -D @playwright/test@latest` in the right workspace package; `npm i -D` for npm repos — pnpm workspaces reject `npm` with `EUNSUPPORTEDPROTOCOL`). Install matching browser: `pnpm exec playwright install chromium`.
- **App running** at a known URL. Note the real port — dynamic-port stacks (Aspire etc.) bake OIDC redirect URIs to the assigned port, so the demo MUST hit that exact port or auth breaks. Verify: `curl -s -o /dev/null -w "%{http_code}" http://localhost:<port>`.
- **ffmpeg** on PATH for mp4 conversion.

## 1. Separate demo config

Recording lives in its OWN config, `playwright.demo.config.ts`, beside the app's `playwright.config.ts` — so the CI config stays lean and the recording knobs (slowMo, 1080p video, action highlights) never touch the gate. Use 1080p — it gives the app enough real estate to lay out naturally; 720p is fine for smaller UIs.

**Dual-mode wiring.** The demo config sets `process.env['DEMO'] = '1'` at module top (before `defineConfig`, so worker forks inherit it) and `testMatch`es the shared spec. The CI config needs NO change — the shared `*.spec.ts` already lives in its `testDir`, and with `DEMO` unset the spec's caption/dwell/style helpers no-op (§2), so it runs as a normal fast gate. (Fallback demo-only path: name the file `*.demo.spec.ts`, `testMatch` it here, and add `testIgnore: /.*\.demo\.spec\.ts/` to the CI config so it never runs there.)

```ts
import { defineConfig, devices } from '@playwright/test';

// Flip the shared spec into demo mode: captions + paced dwells on. Set BEFORE defineConfig so the
// runner's worker forks inherit it. The CI config leaves DEMO unset → same spec runs at full speed.
process.env['DEMO'] = '1';

// Fallback port is a footgun on dynamic-port stacks — a stale/wrong port silently breaks OIDC auth. Set BASE_URL to the real running port.
const baseURL = process.env['BASE_URL'] ?? 'http://localhost:4500';

export default defineConfig({
  testDir: './e2e',
  testMatch: /my-flow\.spec\.ts/,   // the shared dual-mode spec (or /.*\.demo\.spec\.ts/ for the demo-only fallback)
  fullyParallel: false,
  workers: 1,
  retries: 0,
  timeout: 120_000,
  reporter: [['list']],
  use: {
    baseURL,
    ignoreHTTPSErrors: true,

    // Framing: viewport === video.size (see gotchas).
    // deviceScaleFactor stays 1 (see gotchas).
    viewport: { width: 1920, height: 1080 },
    colorScheme: 'light',
    reducedMotion: 'reduce',

    // Pacing: uniform per-action delay so a human can follow.
    launchOptions: { slowMo: 450 },

    video: {
      mode: 'on',
      size: { width: 1920, height: 1080 },
      show: {
        // Outlines each interacted element + labels the action. No fake cursor needed.
        actions: { duration: 800, position: 'bottom-right', fontSize: 20 },
      },
    },

    // Cleanest possible video — no competing capture.
    trace: 'off',
    screenshot: 'off',
  },
  projects: [
    {
      name: 'chromium',
      // Spread devices FIRST, then re-assert framing (see gotchas — spread re-injects a 1280x720 viewport).
      use: { ...devices['Desktop Chrome'], viewport: { width: 1920, height: 1080 }, deviceScaleFactor: 1 },
    },
  ],
});
```

### Framing gotchas (each one produced a bad video)

- **Letterbox / gray bars:** default video scales the viewport into 800x800. Fix — set `video.size === viewport`.
- **Zoomed + fuzzy:** `deviceScaleFactor: 2` with a fixed video size renders at 2x then downscales soft. Fix — keep `deviceScaleFactor: 1`.
- **Content in top-left, rest gray:** `...devices['Desktop Chrome']` re-injects its own 1280x720 viewport AFTER your `use.viewport`. Fix — re-assert `viewport` + `deviceScaleFactor` in the project `use` AFTER the spread (see config above).

### Captions: native vs custom

`video.show.test` (level `file|title|step`) burns the step title on-screen, BUT only at fixed corners/edges (`top`/`bottom`/`top-left`...). No custom offset. For a bottom-center caption (the placement that reads best), DROP `show.test` and draw a custom overlay from the spec (§2). Keep `show.actions` for click outlines either way.

## 2. The spec (dual-mode)

One spec = one continuous flow. Every `test.step()` title is written for the VIEWER and set as the on-screen caption via `caption` (see spec rules below).

**The whole demo layer is gated on a `DEMO` flag** so the same file is a real CI e2e test when `DEMO` is unset. Read it once at module top; every demo-only helper (`caption`, `dwell`, `applyDemoStyles`) returns early without it. The result: identical steps and assertions in both modes — CI runs them fast and headless, the demo config paces + captions + records them.

Standard helpers (adapt selectors to the app):

```ts
import { test, expect, type Page } from '@playwright/test';

// Set to '1' by playwright.demo.config.ts. Unset in CI → every helper below no-ops, so the same
// spec runs as a normal fast e2e gate with the same assertions.
const DEMO = !!process.env['DEMO'];

// Demo-only pause at a semantic boundary (page settled, value landed, hold the final frame).
async function dwell(page: Page, ms: number) {
  if (DEMO) await page.waitForTimeout(ms);
}

// Demo-only: smooth-scroll the SPA and hide the jumpy scrollbar so motion reads well on video.
// Persists across in-app nav (see spec rules below). No-op in CI — no reason to slow its scrolling.
async function applyDemoStyles(page: Page) {
  if (!DEMO) return;
  await page.addStyleTag({
    content: `
      html { scroll-behavior: smooth; }
      *::-webkit-scrollbar { width: 0 !important; height: 0 !important; }
      html { scrollbar-width: none; }
    `,
  });
}

// Demo-only step caption: bottom-center pill (placement rationale in §1). Drawn on
// document.body (outside the app root); see spec rules below for persistence/self-heal
// behavior. No-op in CI.
async function caption(page: Page, text: string) {
  if (!DEMO) return;
  await page.evaluate((label) => {
    const id = 'demo-caption';
    let el = document.getElementById(id);
    if (!el) {
      el = document.createElement('div');
      el.id = id;
      Object.assign(el.style, {
        position: 'fixed',
        left: '50%',
        bottom: '25%',
        transform: 'translateX(-50%)',
        maxWidth: '80vw',
        padding: '14px 28px',
        background: 'rgba(17, 24, 39, 0.88)',
        color: '#fff',
        font: '600 24px/1.3 -apple-system, Segoe UI, Roboto, sans-serif',
        textAlign: 'center',
        borderRadius: '9999px',
        boxShadow: '0 6px 24px rgba(0,0,0,0.35)',
        zIndex: '2147483647',
        pointerEvents: 'none',
      } as CSSStyleDeclaration);
      document.body.appendChild(el);
    }
    el.textContent = label;
  }, text);
}
```

Structure each spec:

```ts
test('<flow title> [Spec: <ticket-id>]', async ({ page }) => {
  const originalValue: string | null = null;   // for the restore-in-finally (see rules)

  await test.step('<first caption>', async () => {
    await page.goto('/');
    // ...login / setup...
    await applyDemoStyles(page);          // once, after first real page loads (no-op in CI)
    await caption(page, '<first caption>');
    await dwell(page, 1200);              // dwell at a semantic boundary (no-op in CI)
  });

  await test.step('<read-only step>', async () => {
    await caption(page, '<read-only step>');
    // ...navigate / tour...
    await expect(/* something the viewer should notice landed */).toBeVisible();
    await dwell(page, 800);
  });

  // Steps that MUTATE data: wrap in try/finally so CI restores the original value and stays
  // idempotent across repeated runs. Skip the restore under DEMO — the edit-back would tail the
  // recording unnarrated, and one synthetic value overwritten next run is harmless.
  try {
    await test.step('<mutating step>', async () => {
      await caption(page, '<mutating step>');
      // originalValue = await field.inputValue();  // capture before editing
      // ...edit + save...
      await expect(/* the change is visible / a success toast */).toBeVisible();
      await dwell(page, 1800);            // hold the final frame
    });
  } finally {
    if (!DEMO && originalValue !== null) {
      // ...restore originalValue...
    }
  }
});
```

### Spec rules

- **`caption(page, '<title>')` as the FIRST line of each step**, text = the step title. Reads as narration; no-op in CI.
- **Captions persist across client-side nav** (same document). After a full page reload the overlay is gone; `caption` re-creates it — so just call it again in the next step.
- **Pace with `slowMo` (config) + `dwell` only at semantic boundaries** (after a page settles, after a value lands, to hold the final state). `dwell` is the ONLY pacing primitive — never raw `page.waitForTimeout` in a step, or CI slows down too.
- **Assert what the viewer should see** (`expect(...).toBeVisible()`) — doubles as a settle point AND is the real e2e assertion when `DEMO` is unset. Assert in every step, not just the demo-worthy ones.
- **Mutations restore in `finally`, gated `if (!DEMO)`** — keeps the CI gate idempotent (seed data un-drifted) without tailing the recording with an un-narrated edit-back.
- **Keep synthetic values under any field length cap** (`maxLength`) — an over-long value is silently truncated on save, so the read-back assertion fails against the un-truncated string. Short + unique (e.g. `` `E2E${Date.now() % 1_000_000}` ``).
- **Scroll tours:** `heading.scrollIntoViewIfNeeded()` + `dwell(page, ~650)` per section pans the record at a readable pace.
- **Strict-mode duplicates:** a control rendered twice (e.g. header + sticky footer) needs `.first()`.
- Waits on dynamic-port stacks: wait on visible UI (datatable rows, headings), never hardcoded ports/URLs.

## 3. Record

`rm -rf test-results` first for a clean run:

```bash
rm -rf test-results
BASE_URL=http://localhost:<port> pnpm exec playwright test --config=playwright.demo.config.ts
```

Clip lands at `test-results/<...>/video.webm`.

## 4. Convert to portable mp4

webm isn't Slack/Safari-friendly. Transcode to H.264:

```bash
WEBM=$(/usr/bin/find test-results -name '*.webm' | head -1)
mkdir -p /tmp/<name>-demo
ffmpeg -y -i "$WEBM" -c:v libx264 -crf 20 -pix_fmt yuv420p -movflags +faststart /tmp/<name>-demo/<name>-demo.mp4
open /tmp/<name>-demo/<name>-demo.mp4   # let the user eyeball framing + captions
```

Use `/usr/bin/find` (not a shell `find` that a proxy may mangle). Lower `-crf` = higher quality/bigger file (18–23 sensible).

## 5. Iterate on quality

After the first record, WATCH it (or have the user watch). Common fixes, in order of how often they bite: framing (§1 gotchas) → caption placement (`bottom` % in `caption`) → pacing (`slowMo` + dwell values) → too fast/slow scroll tours. Re-record after each change; framing bugs are config-only, pacing/captions are spec-only.
