---
name: coding-standards
description: Coding standards to apply when writing, modifying, or reviewing code.
---

# Coding Standards

## Logic lives with its data
Information Expert / no Feature Envy. Coalesce, keep-existing, and parse rules
belong as methods on the command/DTO — not field-by-field in handlers. Handler
deriving one value from 3+ fields of an object → move it onto that object.
Parse strings into value objects at the boundary (parse, don't validate).
Domain invariants stay in the domain; DTOs own only merge/coalesce semantics.
