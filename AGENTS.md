# AGENTS.md

Instructions for AI coding agents working **in this repository**. If you are integrating
MockREST into another project's tests, start from the
[README](README.md) and the [seed/spec format reference](docs/design/rest-format.md) instead.

## Build, test, lint

```sh
swift build
swift test
swift format lint --strict --recursive Sources Tests Package.swift
swift package generate-documentation --target MockRESTCore --target MockREST   # docs must build clean
```

All four must pass before any commit. CI additionally runs the test suite on Linux
(`swift:6.1` container) and on an Android emulator; do not introduce Apple-only framework
imports in library targets.

## Architecture (settled decisions — do not relitigate)

- Two modules: `MockRESTCore` (portable engine — **never import NIO here**) and `MockREST`
  (the `MockService` conformance + `MockRESTServer` facade over `MockCoreTransport`).
- MockREST is a protocol extension of the MockCore platform. Protocol-neutral machinery
  (MockValue, StateStore, generators, seed primitives, diagnostics, MockHost) lives in
  [mockcore-swift](https://github.com/AlexNachbaur/mockcore-swift) — don't duplicate it here,
  and propose changes that benefit every protocol there instead.
- Settled v1 decisions (documented in [docs/design/rest-format.md](docs/design/rest-format.md) §9):
  OpenAPI 3.0/3.1 only, internal `$ref`s only, `resources:` block with `idField` (default
  `"id"`), schema `example`s seed only when no explicit data, `limit`/`offset` pagination with
  envelope synthesis, `?field=` filters and `?sort=` sorting, PUT replaces only (404 when
  absent), body-validation failures are 422 with field paths, JSON-only (406 otherwise).
- Diagnostics are a product feature. Spec, seed, and request errors carry document paths
  (`paths./users/{id}.get.responses.200`, `data.User[0].email`) and "did you mean"
  suggestions. Never regress an error message.
- Dependencies are fixed: mockcore-swift, mockql-swift (test-only, for the cross-protocol
  integration tests), swift-docc-plugin (build-time). Adding any other dependency requires
  asking the maintainer first.

## Code style (enforced)

- swift-format with the checked-in `.swift-format`: 120 columns, 4-space indent.
- No force unwraps anywhere (tests use `try #require(...)`); no `DispatchQueue` — Swift
  concurrency only; prefer value types.
- Never use caseless enums as namespaces; use structs with static members.
- Swift Testing (`import Testing`) for all tests, never XCTest.
- Every public symbol gets a doc comment; DocC must build with zero warnings.

## Testing rules

- Everything requires unit tests (`Tests/MockRESTCoreTests`, driven through
  `MockRESTEngine.execute` in-process).
- Full-stack behavior belongs in `Tests/MockRESTIntegrationTests`: real HTTP round trips via
  `MockRESTServer`, plus the cross-protocol suite proving REST + GraphQL share one `MockHost`
  and one `StateStore` — keep that suite passing in both directions.
- Stop servers/hosts explicitly at the end of a test (`try await server.stop()`) — never in a
  detached `Task` from `defer`, which races process teardown.
- Update `CHANGELOG.md` (Unreleased section) for user-visible changes.
