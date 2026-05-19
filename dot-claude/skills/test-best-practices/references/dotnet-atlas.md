# .NET Assertions: Atlas API Response Workarounds

Atlas-specific patterns. Read `dotnet-awesome-assertions.md` first for general .NET assertion guidance.

## The Problem

Atlas provides custom `Should()` extensions for `ApiResponse<T>` types that return `ApiResponseAssertions<T>` instead of standard `ObjectAssertions`. This custom type lacks `BeEquivalentTo`.

## Solution: Assert on `body.Result`

Assert on `body.Result` (the plain DTO) rather than on the `ApiOkResponse<T>` wrapper. Check HTTP status separately on `response.StatusCode`.

```csharp
// BAD — requires (object) cast to escape Atlas custom assertions
((object)body).Should().BeEquivalentTo(
    new { StatusCode = 200, Result = new { Id = channelId } },
    o => o.ExcludingMissingMembers());

// GOOD — assert status and result separately, no cast needed
using (new AssertionScope())
{
    response.StatusCode.Should().Be(HttpStatusCode.OK);
    body.Result.Should().BeEquivalentTo(
        new { Id = channelId },
        o => o.ExcludingMissingMembers());
}
```

Use `AssertionScope` when checking both status and body since these are genuinely separate assertions that can't be combined.
