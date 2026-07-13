# Extraction Plan — MockQL → MockCore

> Status: **Design draft for review.** Describes refactoring the shipped (pre-1.0) MockQL onto the
> new shared `MockCore` foundation **without breaking its public API or tests**. Depends on
> `architecture.md`.
>
> Note: this work happens in the `mockcore-swift` and `mockql-swift` repos; it lives here only
> because the design was done alongside MockREST. Move it to those repos once they exist.

## 1. Objective & success criteria

- Stand up `mockcore-swift` (`MockCore` + `MockCoreTransport`).
- Move the protocol-neutral pieces out of `MockQLCore`/`MockQL` into MockCore.
- **MockQL's public API is source-compatible** — existing consumer code and all existing MockQL
  tests compile and pass unchanged.
- `swift build`, `swift test`, and `swift format lint --strict` pass on macOS and Linux for both
  packages.

## 2. What moves vs. stays

Grounded in the current MockQL source (already read):

| Piece (current location)                              | Destination            | Notes |
|-------------------------------------------------------|------------------------|-------|
| `Values/GraphQLValue.swift` (+ `+Codable`)            | `MockCore` as `MockValue` | Rename type; keep all cases incl. `.enumValue`. |
| `Store/StateStore.swift`, `MutationState`, `StoreData`| `MockCore`             | Speak only `MockValue` + type/id strings today. |
| `Generators/*` (`FieldGenerator`, `GeneratorContext`, `GeneratorRegistry`, `GeneratorData`, `RandomSource`) | `MockCore` | Verbatim; keyed `"Type.field"`. |
| `Diagnostics/SourceLocation.swift`, `Suggestion.swift`| `MockCore`             | Neutral. |
| `Diagnostics/MockQLError.swift`                        | `MockCore` as `MockError` base | MockQL keeps a GraphQL-flavored wrapper/typealias. |
| `Seed/` value decoding, dup-id, reference-string model | `MockCore` (primitives) | Schema-specific validation stays in MockQL. |
| HTTP plumbing in `MockQL/HTTPHandler.swift`, bootstrap in `MockQLServer.swift` | `MockCoreTransport` as `MockHost` | Generalize `/graphql`-hardcoding into `MockService` routing. |
| SDL/operation parser (`Language/*`), `Schema/*`, `Execution/*`, `Engine/*`, subscriptions, DSL | **stays in MockQL** | GraphQL-specific. |

`GraphQLError` stays in MockQL (GraphQL error shape / locations), built on the shared `MockError`.

## 3. Compatibility shims (in MockQL)

- `public typealias GraphQLValue = MockValue` — covers the vast majority of the public surface
  (seeds, args, records, responses are all `GraphQLValue`).
- Re-export shared symbols from `MockQLCore` (via `@_exported import MockCore` or explicit
  typealiases) so consumers who wrote `MockQLCore.StateStore`, `FieldGenerator`, `RandomSource`,
  `SourceLocation`, etc. keep compiling.
- `MockQLServer` keeps its exact signature; internally it now builds a single-service `MockHost`
  wrapping the GraphQL `MockService`. `server.url` still ends in `/graphql`; `webSocketURL`
  unchanged.
- **[OPEN]** whether `.enumValue`-related helpers need any GraphQL-only naming preserved — audit
  the public API surface during Phase 1.

## 4. Phased execution (each phase ends green)

**Phase 0 — Workspace.** Create `mockcore-swift` with empty `MockCore` + `MockCoreTransport`
targets and CI. Develop MockQL/MockREST against it via **local path dependencies** in a throwaway
`Package.swift` override (or a shared workspace) until MockCore is tagged. Removes the
chicken-and-egg of unpublished packages.

**Phase 1 — Neutral value + store + generators.** Move `MockValue`, `StateStore` & friends,
generators, `RandomSource`, diagnostics primitives into `MockCore`. Add the `GraphQLValue`
typealias and re-exports in MockQL. Build MockQL against MockCore. **Gate:** MockQL's full test
suite passes untouched.

**Phase 2 — Transport / `MockHost` + `MockService`.** Generalize the NIO bootstrap and
`HTTPHandler` into `MockCoreTransport`; define `MockService`, `MockRequest`, `MockResponse`, and
the WebSocket-upgrade hook. Make `MockQLEngine` conform to `MockService`; reimplement
`MockQLServer.start` on top of `MockHost`. **Gate:** MockQL unit + integration tests pass; a new
MockCore-level test starts a `MockHost` with a trivial stub service.

**Phase 3 — Tag & publish.** Cut `mockcore-swift` `0.1.0`. Repoint `mockql-swift` to the tagged
dependency, bump MockQL a **minor** version (additive: new MockCore dep, `MockService`
conformance; no public breakage), update its CHANGELOG.

**Phase 4 — MockREST.** Build `mockrest-swift` on the tagged MockCore per `rest-format.md`
(engine, OpenAPI ingestion, auto-CRUD, DSL, seeds), then an integration test proving REST +
GraphQL on **one** `MockHost` and a cross-protocol flow (REST mutation visible to a GraphQL
query).

## 5. Versioning & repos

- `mockcore-swift` starts at `0.1.0`.
- `mockql-swift`: minor bump; CHANGELOG "Unreleased" notes the foundation extraction and that the
  public API is unchanged.
- `mockrest-swift`: `0.1.0` once Phase 4 lands.
- All three: MIT, `github.com/AlexNachbaur/*`, Swift 6.1, macOS/iOS/Linux CI (Android/Windows as
  MockQL already tracks them).

## 6. Risks & mitigations

- **Hidden GraphQL coupling in "neutral" code.** Mitigation: phases gated by MockQL's existing
  tests; anything that fails to move cleanly stays in MockQL.
- **Public-API drift via re-exports.** Mitigation: audit MockQL's public symbols before Phase 1;
  add typealiases/re-exports until a diff of the public interface is empty.
- **Three-repo dependency churn during development.** Mitigation: local path deps / workspace
  until MockCore is tagged (Phase 0).
- **`MockService` seam churn once REST is real.** Mitigation: Phase 2 ships the seam with a stub
  service *and* GraphQL as consumers, but treat it as unstable until Phase 4 validates it against a
  genuinely different protocol; keep MockCore pre-1.0 so the seam can change.

## 7. Open decisions

1. ✅ Decided 2026-07-12: `MockCoreTransport` (see `architecture.md` §7).
2. ✅ Decided 2026-07-12: local path dependencies until MockCore is tagged (Phase 3 swaps to the
   tagged release).
3. Exact MockQL version bump number and whether to align it with a MockREST `0.1.0` announcement.
4. Resolved during Phase 1: the `GraphQLValue = MockValue` and `MockQLError = MockError`
   typealiases plus `@_exported import MockCore` covered the entire public surface — MockQL's
   full test suite passed with no test edits, and no additional GraphQL-named helpers needed
   preserving.
