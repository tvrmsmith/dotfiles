---
name: contract-approval
description: Gates and tracks approval of API/message contracts that cross a service or independent-deploy boundary. Use before implementing or modifying such a contract, and when a code review needs to know whether a contract was already approved.
---
# Contract Approval

Contracts crossing **service or independent-deploy boundary** expensive to reverse once consumer depends on them. Gate them: surface contract, get explicit approval, record approval durably so any later session (including code review) can tell it approved and check drift.

## What counts as a cross-boundary contract

Gate these:

- **service ↔ service** — HTTP/gRPC between two independently-deployable services
- **frontend ↔ BFF/backend** — BFF endpoint frontend consumes
- **Kafka / event schemas** consumed by other services
- **published/versioned APIs** consumed outside owning service

Gate only contracts with an external consumer; internal seams changed within one service/PR — module interfaces, private seams, internal DTOs — stay ungated.

## When to run the gate

- Before **implementing or modifying** cross-boundary contract.
- Prefer fold contract approval into **spec review** when spec exists — surface contracts as part of spec, not separate step. Spec not cover contract → define + approve before building past it.
- During **code review**, check whether contract already approved.

## Contract identity

Stable, human-readable key naming contract by *what it is*. Derive same way every time so later session names same contract identically:

- **HTTP:** `<service> <METHOD> <path>` — e.g. `orders-api POST /orders`, `web-bff GET /patients/{id}/schedule`
- **gRPC:** `<Service>.<Rpc>` — e.g. `SchedulingService.ReserveSlot`
- **Event:** `<topic> <EventType>[ <version>]` — e.g. `patient.events PatientAdmitted v1`

Identity = lookup key.

## Contract format — YAML

Stored contract = **native artifact**, as YAML:

- **APIs** → OpenAPI (YAML)
- **JSON messaging** → JSON Schema (YAML — JSON Schema tooling accepts YAML since YAML superset of JSON)

Stored artifact *is* the contract — usable — not fingerprint of it. For code-generated specs code is source; render/derive its YAML for record rather than hand-editing generated output.

## Storage — bd primary, `.contracts` fallback

Record shape identical in both — one JSON object:

```json
{"identity":"orders-api POST /orders","format":"openapi","contract":"<yaml text>","approvedAt":"2026-07-10","issue":"<id>"}
```

`format` is `openapi` or `json-schema`. `contract` is YAML artifact as JSON string (newlines escaped). Recording your first contract → see `EXAMPLE.md` for a fully filled record.

**Primary: `bd`** (where repo has beads) — syncs via git refs so teammates and other machines see it, worktree-safe. Store JSON record as decision body:

```bash
# look up
bd search "orders-api POST /orders"     # then parse the decision body with jq
# record on the current issue
bd decision add --issue <issue-id> '<json record>'
```

**Fallback: local JSONL** (where repo has no bd) — store in git **common dir** so shared across all worktrees of repo, branch-independent:

```bash
LEDGER="$(git rev-parse --git-common-dir)/contracts-approvals.jsonl"
# look up
jq -r 'select(.identity=="orders-api POST /orders").contract' "$LEDGER"
# record
printf '%s\n' '<json record>' >> "$LEDGER"
```

Fallback ledger local-only (not committed/pushed).

## Gate flow

1. Derive **identity** from code being implemented.
2. Look it up (bd, else JSONL fallback).
   - **Found** → **drift check**: derive current contract's YAML and diff against stored `contract`. Equal → proceed. Different → built contract drifted from what approved; show diff and re-surface for approval.
   - **Not found** → gate: present contract, get approval, record it, then proceed.
3. **Modifying** already-approved contract → re-approve.

## Presenting the contract for approval

Show it **readably** — default **markdown tables** inline; use **lavish** or another format if user asks. (Spec/plan reviews default to lavish per global preference; contract surfaced inside lavish spec review rides along in lavish.)

Markdown example:

```
### POST /orders  (orders-api)
**Request**
| field     | type    | req | constraints |
|-----------|---------|-----|-------------|
| patientId | uuid    | yes |             |
| items     | Item[]  | yes | minItems=1  |

**Response 201**
| field  | type                 |
|--------|----------------------|
| id     | uuid                 |
| status | enum(created\|queued)|
```

On approval, store full YAML artifact in record (above), and — where project keeps canonical spec file — write it there too so artifact lives with code.