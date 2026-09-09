# CDP element interaction and waiting over `chrome-agent`

Research for `dotfiles-cks.6`. Every command below was run against `chrome-agent` 0.5.8 driving
Chrome 152.0.7977.83 headless on macOS, on local `file://` test pages. Claims marked *measured* were
observed in that session; claims marked *protocol* come from the CDP definition read out of the
running browser (`chrome-agent help <instance> <Domain.method>`) or from
https://chromedevtools.github.io/devtools-protocol/tot/ .

## The recipe

Four steps. Do not skip step 1 or step 4.

```bash
INST=tmp-01   # from `chrome-agent status`

# 1. LOCATE. One Runtime.evaluate that scrolls, measures, and hit-tests atomically.
chrome-agent $INST Runtime.evaluate '{"expression":"(()=>{const el=document.querySelector(\"#submit\");if(!el)return{err:\"no match\"};el.scrollIntoView({block:\"center\"});const r=el.getBoundingClientRect();const x=Math.round(r.x+r.width/2),y=Math.round(r.y+r.height/2);const hit=document.elementFromPoint(x,y);return{x,y,ok:!!hit&&(hit===el||el.contains(hit)),hit:hit?hit.tagName+\"#\"+hit.id:null};})()","returnByValue":true}'
# -> {"result":{"type":"object","value":{"x":50,"y":426,"ok":true,"hit":"SPAN#inner"}}}

# 2. ABORT if ok is false. Something is on top of the element, or it is off-viewport.

# 3. ACT. A click is press + release, both with clickCount:1, at the coords from step 1.
chrome-agent $INST Input.dispatchMouseEvent '{"type":"mousePressed","x":50,"y":426,"button":"left","clickCount":1}'
chrome-agent $INST Input.dispatchMouseEvent '{"type":"mouseReleased","x":50,"y":426,"button":"left","clickCount":1}'

# 4. VERIFY by re-query. Never by the dispatch return value.
chrome-agent $INST Runtime.evaluate '{"expression":"document.querySelector(\"#result\").textContent","returnByValue":true}'
```

## Deriving coordinates: use `Runtime.evaluate`, not `DOM.querySelector` + `DOM.getBoxModel`

Use `getBoundingClientRect` inside `Runtime.evaluate`. The DOM-domain route is not merely slower
through `chrome-agent`, it is broken, because each one-shot `chrome-agent <inst> Domain.method` opens
a fresh CDP session and `nodeId` is scoped to a session.

Measured:

```bash
chrome-agent tmp-01 DOM.getDocument '{"depth":0}'     # -> root nodeId 1, backendNodeId 2
chrome-agent tmp-01 DOM.querySelector '{"nodeId":1,"selector":"#submit"}'
# -> CDP error -32000: Could not find node with given id
```

`nodeId` 1 is stable-looking across calls and still invalid, which is the worst kind of trap. The
same applies to `objectId` from `Runtime.evaluate`:

```bash
chrome-agent tmp-01 Runtime.evaluate '{"expression":"document.querySelector(\"#submit\")"}'
# -> objectId "6101856440034346608.1.1"
chrome-agent tmp-01 DOM.getBoxModel '{"objectId":"6101856440034346608.1.1"}'
# -> CDP error -32000: Could not find object with given id
```

Only `backendNodeId` survives between one-shot calls (*measured*; the protocol calls it "a node that
may not have been pushed to the front-end"). Getting one without a session means either
`DOM.getNodeForLocation '{"x":..,"y":..}'` (which needs the coordinates you are trying to compute) or
`DOM.getDocument '{"depth":-1}'` plus a client-side walk of the whole tree. Both are more work than
one `Runtime.evaluate`.

Coordinate space is not the differentiator. With `#submit` scrolled to a rect of
`y: 401.875, height: 49`, `DOM.getBoxModel` returned a border quad of
`[0, 401.875, 100.03, 401.875, 100.03, 450.875, 0, 450.875]` (*measured*), so both are viewport-relative
CSS pixels, matching `Input.dispatchMouseEvent`'s documented space: "X coordinate of the event
relative to the main frame's viewport in CSS pixels" (*protocol*). The official DOM docs never state
the space for `getBoxModel`; only `DOM.getContentQuads` says "relative to viewport". Do not rely on
undocumented agreement.

Reach for the DOM domain only when you hold a persistent session (`chrome-agent attach`, or the
Python API), or for the things `Runtime.evaluate` cannot do: `DOM.setFileInputFiles`,
`DOM.getDocument '{"pierce":true}'` across shadow roots and cross-origin iframes.

## Scroll into view

Prefer in-page `el.scrollIntoView({block:"center"})` inside the same evaluate that measures. Measuring
before scrolling is the classic flake, and two separate calls let layout move in between.

`DOM.scrollIntoViewIfNeeded '{"backendNodeId":8}'` also works and returns `{}` (*measured*), but it needs
a `backendNodeId` you had to hunt for, and it lands the element at a scroll position you then still
have to measure.

That measurement is not optional. In one run I scrolled the same element into view twice from
different starting scroll positions and got centre `y: 426` the first time and `y: 291` the second
(*measured*). Coordinates cached from an earlier scroll click empty space.

## The exact event sequence for a real click

`clickCount` is load-bearing. Its protocol default is 0 (*protocol*: "Number of times the mouse button
was clicked (default: 0)"), and with the default no `click` event is generated at all.

Measured, press + release at the correct coordinates with `clickCount` omitted:

```
pointerdown trusted=true detail=0
mousedown   trusted=true detail=0
pointerup   trusted=true detail=0
mouseup     trusted=true detail=0
```

No `click`. The page's click handler never ran, and both dispatch calls returned `{}`.

The same pair with `"clickCount":1`:

```
pointerdown trusted=true detail=0
mousedown   trusted=true detail=1
pointerup   trusted=true detail=0
mouseup     trusted=true detail=1
click       trusted=true detail=1
```

So: `mousePressed` then `mouseReleased`, same `x`/`y`, `"button":"left"`, `"clickCount":1`. Events
arrive with `isTrusted true`.

Extras:

- **Double click.** Send the single click, then a second press/release pair with `"clickCount":2`.
  That emits `click detail=2` followed by `dblclick` (*measured*).
- **Hover-gated UI.** `mousePressed` alone does not set `:hover`. A prior
  `Input.dispatchMouseEvent '{"type":"mouseMoved","x":50,"y":291}'` at the real coordinates does
  (`document.querySelector("#submit:hover")` went from null to the element, *measured*). Send
  `mouseMoved` first when a menu opens on hover.
- **Synthetic vs trusted.** `Runtime.evaluate` running `el.click()` is fine on ordinary UIs and is one
  call. Escalate to `Input` events when a synthetic click silently no-ops, when the target is in a
  cross-origin iframe, or when the UI gates on `isTrusted`.

## Text input

Focus first, by clicking the field with the recipe above. Then:

```bash
chrome-agent $INST Input.insertText '{"text":"hello@example.com"}'
```

Measured: value becomes `hello@example.com` and the page sees `input` with `isTrusted true`.
`insertText` emits no `keydown`/`keyup` (*protocol*: "emulates inserting text that doesn't come from a
key press, for example an emoji keyboard or an IME"). Use it for bulk text; it is one call instead of
two per character.

For individual keys, and for anything listening on `keydown`:

```bash
# printable character: `text` is what makes it type
chrome-agent $INST Input.dispatchKeyEvent '{"type":"keyDown","text":"!","key":"!","windowsVirtualKeyCode":49}'
chrome-agent $INST Input.dispatchKeyEvent '{"type":"keyUp","key":"!","windowsVirtualKeyCode":49}'
# editing key: no `text`
chrome-agent $INST Input.dispatchKeyEvent '{"type":"keyDown","key":"Backspace","windowsVirtualKeyCode":8,"nativeVirtualKeyCode":8}'
chrome-agent $INST Input.dispatchKeyEvent '{"type":"keyUp","key":"Backspace","windowsVirtualKeyCode":8,"nativeVirtualKeyCode":8}'
# submit
chrome-agent $INST Input.dispatchKeyEvent '{"type":"keyDown","key":"Enter","text":"\r","windowsVirtualKeyCode":13}'
```

All three verified: `!` appended, Backspace removed it, Enter fired the input's `change` event
(*measured*).

React-controlled inputs that ignore the above need the native value setter, per upstream's guide:

```bash
chrome-agent $INST Runtime.evaluate '{"expression":"(()=>{const el=document.querySelector(\"#email\");const set=Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,\"value\").set;set.call(el,\"a@b.com\");el.dispatchEvent(new Event(\"input\",{bubbles:true}));})()"}'
```

## Waiting without sleeps

Two mechanisms. Pick by what you are waiting on.

### A DOM condition: await a promise inside the page

One call, wakes the instant the condition holds, and carries its own timeout.

```bash
cat > /tmp/wait.js <<'EOF'
new Promise((resolve, reject) => {
  const sel = "#late";
  const found = () => document.querySelector(sel);
  if (found()) return resolve("already");
  const obs = new MutationObserver(() => { if (found()) { obs.disconnect(); clearTimeout(t); resolve("appeared"); } });
  obs.observe(document, { childList: true, subtree: true });
  const t = setTimeout(() => { obs.disconnect(); reject(new Error("timeout waiting for " + sel)); }, 5000);
})
EOF
python3 -c 'import json;print(json.dumps({"expression":open("/tmp/wait.js").read(),"awaitPromise":True,"returnByValue":True}))' > /tmp/wait.json
chrome-agent $INST Runtime.evaluate "$(cat /tmp/wait.json)"
```

Against an element injected at 1500 ms, this returned `{"result":{"type":"string","value":"appeared"}}`
after 1.518 s wall clock (*measured*). `awaitPromise:true` is required; without it the call returns a
pending promise handle immediately.

Build the JSON with `python3 -c 'import json...'` rather than hand-escaping a multi-line expression
into a shell single-quoted string. That is where these commands actually break.

### A browser event: background `attach` plus a blocking waiter

For navigation, network and console, subscribe once and block on the stream. Upstream ships the
waiter as `scripts/cdp-wait.py` in the chrome-agent repo (not in the installed wheel; fetch it from
`https://raw.githubusercontent.com/captivus/chrome-agent/main/scripts/cdp-wait.py`).

```bash
chrome-agent attach $INST +Page.loadEventFired +Page.frameNavigated +Runtime.exceptionThrown > /tmp/events.jsonl 2>&1 &
python3 /tmp/cdp-wait.py --file /tmp/events.jsonl --contains '"status": "ready"' --timeout 10 --print-offset
chrome-agent $INST Page.navigate '{"url":"file:///tmp/page.html"}'
python3 /tmp/cdp-wait.py --file /tmp/events.jsonl --method Page.loadEventFired --timeout 15 --print-offset
```

Measured: the ready line matched at `offset=83`, `Page.loadEventFired` matched at `offset=642`, and
the second wait returned 0.369 s after the navigate command started (most of which is process
startup).

Three details in that script that matter:

- It reads from `--from-offset` (default 0), not from EOF, so it still matches an event that fired
  before the wait started. `tail -f` drops those, which is the subtle version of this bug.
- Chain waits by passing the `offset=<n>` that `--print-offset` writes to stderr into the next call's
  `--from-offset`, so consecutive waits do not re-match a consumed event.
- Exit code 0 matched, 1 timed out, 2 usage error. That is the only exit code in this whole document
  you can trust.

Block on the `{"status": "ready"}` line before dispatching the action, otherwise the action can race
the subscription. `--method` deliberately never matches the ready or error preamble lines, so waiting
on those needs `--contains`.

## Failure modes

1. **`Input.dispatchMouseEvent` returns `{}` whether or not it hit anything.** Measured three ways in
   one session: a click at stale pre-scroll coordinates (`y: 2126`, past the bottom of a 469 px
   viewport), a click without `clickCount`, and a click blocked by a full-screen overlay. All six
   dispatches returned `{}` and the page did not change. The return value carries no information.
   Verification is always a re-query of an independent piece of state.
2. **`Runtime.evaluate` exits 0 on an uncaught exception.** A rejected wait promise returned exit
   code 0 with the error only in the body:
   `{"result":{"type":"object","value":{}},"exceptionDetails":{"exceptionId":1,"text":"Uncaught (in promise) Error: timeout waiting for #never",...}}`
   (*measured*). Parse for the `exceptionDetails` key. Never branch on `$?`.
3. **Stale coordinates read as success.** cks.1 recorded a hardcoded coordinate guess that "passed"
   because it happened to land inside the button. The inverse also holds: reusing coordinates from
   an earlier scroll silently clicks background. Measure inside the same evaluate that scrolls, and
   never reuse coordinates across steps.
4. **A covering overlay is invisible to CDP.** Cookie banners, modal backdrops and toasts absorb the
   click and report nothing. The `document.elementFromPoint` preflight in step 1 catches it, and did
   (`ok: false, hit: "DIV#overlay"`, *measured*).
5. **`hit === el` is too strict.** A button wrapping a `<span>` hit-tests to the span. Accept
   `hit === el || el.contains(hit)`.
6. **`nodeId` and `objectId` are session-scoped, and one-shots are separate sessions.** Covered above.
   Only `backendNodeId` crosses calls.
7. **`insertText` into an unfocused page goes nowhere.** With `document.activeElement` still `BODY`,
   `Input.insertText` returned `{}` and the field stayed empty (*measured*). Click the field first and
   assert `document.activeElement.id`.

## Sources

- Chrome DevTools Protocol, tip-of-tree, read out of Chrome 152 via `chrome-agent help <inst> <method>`
  for `Input.dispatchMouseEvent`, `Input.insertText`, `DOM.scrollIntoViewIfNeeded`, `DOM.getBoxModel`.
- https://chromedevtools.github.io/devtools-protocol/tot/DOM/ for `NodeId` / `BackendNodeId` lifetime
  and `getContentQuads` coordinate space.
- `chrome-agent guide --path` ->
  `~/.local/share/uv/tools/chrome-agent/lib/python3.13/site-packages/chrome_agent/AGENTS.md`
  (drive-the-UI loop, escalation rule, React native-setter idiom, push/pull channels).
- `scripts/cdp-wait.py` from https://github.com/captivus/chrome-agent .
- Bead `dotfiles-cks.1` resolution comment, for the verified macOS transcript this builds on.
