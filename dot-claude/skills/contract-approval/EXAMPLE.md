# Worked Example — Filled Approval Record

Mirrors the record shape in SKILL.md §Storage — a shape change there needs mirroring here. Concrete filled record:

```json
{"identity":"orders-api POST /orders","format":"openapi","contract":"openapi: 3.1.0\npaths:\n  /orders:\n    post:\n      requestBody:\n        content:\n          application/json:\n            schema:\n              type: object\n              required: [patientId, items]\n              properties:\n                patientId: {type: string, format: uuid}\n                items: {type: array, minItems: 1}\n","approvedAt":"2026-07-10","issue":"emr-1234"}
```
