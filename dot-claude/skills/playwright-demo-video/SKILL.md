---
name: playwright-demo-video
description: Record a clean, human-watchable walkthrough video of a web app with Playwright. Use when asked to make a demo/walkthrough/screen-recording video of a feature or flow. Triggers on "demo video", "playwright video".
disable-model-invocation: true
---

# Playwright Demo Video

Record ONE continuous, narrated-by-captions walkthrough clip of a real running app — a clip a human watches, not failure forensics. Uses Playwright's native recording (>= 1.59 for in-video annotations), a custom caption overlay, and ffmpeg for a portable mp4.

## 0. Prereqs

- **Playwright >= 1.59** for `video.show` (action highlights). Check: `pnpm exec playwright --version` (or `npx`). Below 1.59 → upgrade (`pnpm add -D @playwright/test@latest` in the right workspace package; `npm i -D` for npm repos — pnpm workspaces reject `npm` with `EUNSUPPORTEDPROTOCOL`). Install matching browser: `pnpm exec playwright install chromium`.
- **App running** at a known URL. Note the real port — dynamic-port stacks (Aspire etc.) bake OIDC redirect URIs to the assigned port, so the demo MUST hit that exact port or auth breaks. Verify: `curl -s -o /dev/null -w "%{http_code}" http://localhost:<port>`.
- **ffmpeg** on PATH for mp4 conversion.

## 1. Separate demo config

Keep demo recording OUT of the CI config. New file `playwright.demo.config.ts` beside the app's `playwright.config.ts`, and add `testIgnore: /.*\.demo\.spec\.ts/` to the CI config so demo specs never run in CI. Use 1080p — it gives the app enough real estate to lay out naturally; 720p is fine for smaller UIs.

```ts
import { defineConfig, devices } from '@playwright/test';

// Fallback port is a footgun on dynamic-port stacks — a stale/wrong port silently breaks OIDC auth. Set BASE_URL to the real running port.
const baseURL = process.env['BASE_URL'] ?? 'http://localhost:4500';

export default defineConfig({
  testDir: './e2e',
  testMatch: /.*\.demo\.spec\.ts/,
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

## 2. The demo spec

One `*.demo.spec.ts` = one continuous flow. Every `test.step()` title is written for the VIEWER and set as the on-screen caption via `setCaption` (see spec rules below).

Standard helpers (adapt selectors to the app):

```ts
import { test, expect, type Page } from '@playwright/test';

// Smooth-scroll the SPA and hide the jumpy scrollbar so motion reads well on video.
// Persists across in-app nav (see spec rules below).
async function applyDemoStyles(page: Page) {
  await page.addStyleTag({
    content: `
      html { scroll-behavior: smooth; }
      *::-webkit-scrollbar { width: 0 !important; height: 0 !important; }
      html { scrollbar-width: none; }
    `,
  });
}

// Custom step caption: bottom-center pill (placement rationale in §1). Drawn on
// document.body (outside the app root); see spec rules below for persistence/self-heal
// behavior.
async function setCaption(page: Page, text: string) {
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
test('<viewer-facing title of the whole flow>', async ({ page }) => {
  await test.step('<first caption>', async () => {
    await page.goto('/');
    // ...login / setup...
    await applyDemoStyles(page);          // once, after first real page loads
    await setCaption(page, '<first caption>');
    await page.waitForTimeout(1200);      // dwell at a semantic boundary
  });

  await test.step('<next caption>', async () => {
    await setCaption(page, '<next caption>');
    // ...one meaningful interaction...
    await expect(/* something the viewer should notice landed */).toBeVisible();
    await page.waitForTimeout(800);
  });
  // ...more steps... end by holding the final state (waitForTimeout(~1800)).
});
```

### Spec rules

- **`setCaption(page, '<title>')` as the FIRST line of each step**, text = the step title. Reads as narration.
- **Captions persist across client-side nav** (same document). After a full page reload the overlay is gone; `setCaption` re-creates it — so just call it again in the next step.
- **Pace with `slowMo` (config) + dwell `waitForTimeout` only at semantic boundaries** (after a page settles, after a value lands, to hold the final state).
- **Assert what the viewer should see** (`expect(...).toBeVisible()`) — doubles as a settle point and proves the flow really worked.
- **Scroll tours:** `heading.scrollIntoViewIfNeeded()` + `waitForTimeout(~650)` per section pans the record at a readable pace.
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

After the first record, WATCH it (or have the user watch). Common fixes, in order of how often they bite: framing (§1 gotchas) → caption placement (`bottom` % in `setCaption`) → pacing (`slowMo` + dwell values) → too fast/slow scroll tours. Re-record after each change; framing bugs are config-only, pacing/captions are spec-only.
