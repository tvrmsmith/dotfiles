# Type Design Review

Evaluate new/changed types. Core principle: **make illegal states unrepresentable.** Good type lets compiler enforce invariants so bad states can't exist.

## What to check

- **Encapsulation** — internals hidden; no exposed mutable fields/collections that let callers break invariants. Mutation goes through methods that preserve validity.
- **Invariant expression** — constraints encoded in type, not just comments or runtime checks. Prefer smart constructors / validated value objects over primitives (avoid primitive obsession, stringly-typed data).
- **Illegal states** — can invalid instance be built? Optional fields really required-in-some-mode, booleans that should be sum type, nullable soup — flag them. Prefer discriminated unions / sum types over flag combos.
- **Anemic models** — data bags with no behavior where behavior belongs with data.
- **Enforcement** — invariants enforced at construction and mutation, or only by convention?

## Ratings (1–10 each)

- **Encapsulation** — how well internals/invariants protected.
- **Invariant Expression** — how much type system carries constraints.
- **Usefulness** — does type make correct code easy, wrong code hard?
- **Enforcement** — invariants guaranteed vs merely hoped for?

## Output

Per type: the four ratings above, then findings labeled by shared severity. Redesign examples: "replace bool pair with sum type", "make field private + validate in ctor", "wrap string in value object". Note well-designed types too.