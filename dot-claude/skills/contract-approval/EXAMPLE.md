# Worked Example — Filled Approval Record

Mirrors the record shape in SKILL.md §Storage — a shape change there needs mirroring here. Concrete filled record:

```json
{"identity":"orders-api POST /orders","format":"openapi","contract":"openapi: 3.1.0\npaths:\n  /orders:\n    post:\n      requestBody:\n        content:\n          application/json:\n            schema:\n              type: object\n              required: [patientId, items]\n              properties:\n                patientId: {type: string, format: uuid}\n                items: {type: array, minItems: 1}\n","approver":"Trevor","approvedIn":"approved, but make items minItems 1 not 0","approvedAt":"2026-07-10","issue":"emr-1234"}
```

`approvedIn` quotes the approving turn rather than paraphrasing it. Here it also carries a condition the approval was contingent on, which is why the quote is worth more than a boolean.

A record you cannot fill `approver` and `approvedIn` on is PENDING, not approved. See SKILL.md §Who can approve.
