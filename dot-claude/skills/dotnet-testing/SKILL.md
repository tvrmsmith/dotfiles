---
name: dotnet-testing
description: Use when writing or reviewing .NET test assertions (NUnit, AwesomeAssertions/FluentAssertions). Triggers on: test assertion, should, BeEquivalentTo, assertion scope, test style, dotnet test, unit test assertions, acceptance test assertions.
---

# .NET Test Assertion Guidelines

## Core Principle: One Assertion Per Value

Never chain back-to-back `.Should()` calls on the same variable. Each value should be verified in a single assertion expression whose method name describes the expected outcome.

```csharp
// BAD — back-to-back assertions on same value
result.Page.Should().Be(2);
result.PageSize.Should().Be(3);
result.TotalResults.Should().Be(10);

// GOOD — single BeEquivalentTo with anonymous object
result.Should().BeEquivalentTo(
    new { Page = 2, PageSize = 3, TotalResults = 10 },
    o => o.ExcludingMissingMembers());
```

## Use `BeEquivalentTo` With Anonymous Objects

Prefer `BeEquivalentTo` with an anonymous object to verify multiple properties at once. Use `ExcludingMissingMembers()` when the anonymous object is a subset of the actual.

```csharp
// Verify specific properties on a complex object
response.Should().BeEquivalentTo(
    new { StatusCode = 200, Result = new { Id = expectedId } },
    o => o.ExcludingMissingMembers());
```

### Type + Value Checking

`BeEquivalentTo` does NOT check types by default — it's purely structural. When you need to verify the object is a specific type AND has expected values, use `BeOfType<T>().Which` to narrow the type, then `BeEquivalentTo` with an anonymous object for property values:

```csharp
// BAD — only checks property values, not type
actual.Should().BeEquivalentTo(new { Name = "foo" });

// GOOD — verifies type, then checks property values
actual.Should().BeOfType<ExpectedType>()
    .Which.Should().BeEquivalentTo(new { Name = "foo" });
```

Note: Using a typed expected object (e.g., `new ExpectedType { ... }`) with `BeEquivalentTo` does NOT enforce type matching — it still only compares structurally. The `BeOfType<T>().Which` chain is a single fluent expression, not back-to-back assertions.

> **AwesomeAssertions 9.4 note**: `WithStrictTyping()` / `WithStrictTypingFor()` are not available. Use `BeOfType<T>().Which` for type enforcement.

For collections, use `BeEquivalentTo` instead of chaining `HaveCount` + element assertions:

```csharp
// BAD
items.Should().HaveCount(2);
items[0].Name.Should().Be("Alice");
items[1].Name.Should().Be("Bob");

// GOOD
items.Should().BeEquivalentTo(new[]
{
    new { Name = "Alice" },
    new { Name = "Bob" }
}, o => o.ExcludingMissingMembers());
```

When verifying a single collection property (like count), a direct assertion is fine:

```csharp
body.Result.Items.Should().HaveCount(2);
```

## No Null-Forgiving (`!`) or Null-Conditional (`?.`) in Assertions

Never use `!` (null-forgiving) to dereference a potentially null value before asserting. Never use `?.` — it silently skips the assertion chain if the value is null, causing a false pass.

```csharp
// BAD — nullable dereference, poor failure message
response.Headers.Location!.OriginalString.Should().Contain("/items/123");

// BAD — silently passes if Location is null
response.Headers.Location?.OriginalString.Should().Contain("/items/123");

// GOOD — construct the expected value, single assertion
response.Headers.Location.Should().Be(new Uri(Client.BaseAddress!, Route($"/{item.Id}")));
```

Note: `Client.BaseAddress!` is acceptable because `BaseAddress` is set during test setup and is a precondition, not the value under test.

## The Assertion Method Should Describe the Expected Value

Choose assertion methods that make the expectation self-documenting:

```csharp
// BAD — generic
result.Should().NotBeNull();
result.Name.Should().Be("expected");

// GOOD — assertion method tells you what's expected
result.Should().BeEquivalentTo(new { Name = "expected" }, o => o.ExcludingMissingMembers());

// GOOD — specific assertion methods
response.StatusCode.Should().Be(HttpStatusCode.OK);
items.Should().ContainSingle()
    .Which.Should().BeOfType<MyType>()
    .Which.Should().BeEquivalentTo(new { Name = "expected" });
```

## AssertionScope for Unavoidable Multi-Assertions

When multiple assertions on the same value truly cannot be combined into `BeEquivalentTo` (e.g., mixing type checks with property checks, or assertions with different comparison strategies), wrap them in an `AssertionScope`. This reports ALL failures at once instead of stopping at the first.

```csharp
using (new AssertionScope())
{
    response.StatusCode.Should().Be(HttpStatusCode.Created);
    response.Headers.Location.Should().Be(new Uri(Client.BaseAddress!, Route($"/{created.Id}")));
    body.Result.ChannelName.Should().Be(request.ChannelName);
}
```

Without the scope, only the first failure is reported and subsequent assertions are never evaluated. The scope ensures the caller sees all issues in one test run.

## Atlas Response Type Workaround

Atlas provides custom `Should()` extensions for `ApiResponse<T>` types that return `ApiResponseAssertions<T>` instead of standard `ObjectAssertions`. This custom type lacks `BeEquivalentTo`.

**Solution**: Assert on `body.Result` (the plain DTO) rather than on the `ApiOkResponse<T>` wrapper. Check HTTP status separately on `response.StatusCode`.

```csharp
// BAD — requires (object) cast to escape Atlas custom assertions
((object)body).Should().BeEquivalentTo(
    new { StatusCode = 200, Result = new { Id = channelId } },
    o => o.ExcludingMissingMembers());

// GOOD — assert status and result separately, no cast needed
response.StatusCode.Should().Be(HttpStatusCode.OK);
body.Result.Id.Should().Be(channelId);
```

## Audit Trail Assertions

For audit trail verification, use `ContainSingle().Which` with `BeOfType<T>().Which` to verify the type, then `BeEquivalentTo` with an anonymous object for property values:

```csharp
_auditor.AuditTrailLogs.Should().ContainSingle()
    .Which.Should().BeOfType<MirthChannelAuditTrail>()
    .Which.Should().BeEquivalentTo(new
    {
        Action = AuditExtensions.ActionMirthChannelRetrieved,
        ChannelId = channelId,
        Succeeded = true
    });
```

> **Why anonymous objects for `BeEquivalentTo`?** Typed expected objects (e.g., `new MirthChannelAuditTrail(...)`) inherit base class properties like `Timestamp` that differ between expected and actual instances — causing spurious failures. `BeOfType<T>().Which` handles type enforcement, then anonymous objects let you check only the properties you care about.

## Quick Reference

| Scenario | Pattern |
|----------|---------|
| Multiple properties | `BeEquivalentTo(new { ... }, o => o.ExcludingMissingMembers())` |
| Collection contents | `BeEquivalentTo(new[] { new { ... }, ... })` |
| Collection count only | `HaveCount(n)` |
| Single collection item + type | `ContainSingle().Which.Should().BeOfType<T>().Which.Should().BeEquivalentTo(new { ... })` |
| Type check only | `BeOfType<T>()` |
| Nullable value | Construct expected value, use `Be()` — no `!` or `?.` |
| Multiple unrelated assertions | Wrap in `AssertionScope` |
| Atlas response body | Assert on `body.Result`, not `body` |
