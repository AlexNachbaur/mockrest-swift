# MockREST Integration Guide for AI Coding Agents

You are integrating **MockREST** — a stateful, OpenAPI-driven REST mocking server in Swift —
into a project's test suite. This document is self-contained: it gives you the exact APIs, the
canonical patterns, and the mistakes to avoid. Copy it into the consuming project's agent
instructions (`AGENTS.md` / `CLAUDE.md`) or reference it by URL.

Requirements: Swift 6.3+, macOS 14+/iOS 17+ hosts (also runs on Linux, Windows, and Android).
MockREST is a **test-time tool**: add it to test targets only, never to an app target, and
never expose it to non-loopback networks.

## Install

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/AlexNachbaur/mockrest-swift.git", from: "0.1.0")
],
// in the UI/integration test target only:
.testTarget(
    name: "MyAppUITests",
    dependencies: [.product(name: "MockREST", package: "mockrest-swift")]
)
```

In Xcode projects: File ▸ Add Package Dependencies…, link the `MockREST` library to the UI
testing bundle.

## The canonical XCUITest pattern

Follow this shape unless the project already has a different established one:

```swift
import MockREST
import XCTest

final class ProfileTests: XCTestCase {
    var server: MockRESTServer!
    var app: XCUIApplication!

    override func setUp() async throws {
        let bundle = Bundle(for: ProfileTests.self)
        let specPath = try XCTUnwrap(bundle.path(forResource: "api", ofType: "yaml"))
        let seedPath = try XCTUnwrap(bundle.path(forResource: "world", ofType: "yaml"))

        server = try await MockRESTServer.start(
            spec: .file(specPath),     // reuse the project's real OpenAPI document
            seed: .file(seedPath)      // validated against the spec before the port binds
        ) {
            // Only for routes that need custom behavior; everything else is auto-wired.
            Post("/users/{userId}/verify") { req, state in
                state.update("User", id: req.pathParam("userId")) { $0["verified"] = true }
                return .ok(state["User", id: req.pathParam("userId")])
            }
        }
        app = XCUIApplication()
        app.launchEnvironment["API_BASE_URL"] = server.url.absoluteString
    }

    override func tearDown() async throws {
        try await server?.stop()
    }
}
```

The app under test must read its base URL from the launch environment (or an equivalent
injection point). If it hard-codes a host, add that seam first — it is the one change the app
itself needs.

## Rules that prevent the common failures

- **Never pass a relative path to `.file(...)`.** It resolves against the process's working
  directory, which for a test bundle is not the project folder. Add the spec and seed to the
  test target's resources and build the path from `Bundle(for:)` (Xcode) or `Bundle.module`
  (SwiftPM, with `resources: [.copy("Fixtures")]` on the target).
- **Let the spec do the work.** Every path in the spec answers and every resource collection
  gets CRUD, filtering (`?field=value`), sorting (`?sort=field` / `?sort=-field`), and
  `limit`/`offset` pagination. Do not hand-write a `Get`/`Post` for a route auto-CRUD already
  serves correctly.
- **Seed only what the test asserts on.** Omitted fields are generated deterministically and
  stay stable for the server's lifetime; pin a value in the seed (or bind a generator) only
  when the test reads it.
- **Use ids as strings in seeds and handlers.** The store keys records by string id.
- **A handler's writes commit when the closure returns**, atomically. Read back through `state`
  inside the same closure to return what you just wrote.
- **Bind port `0`** (the default) and read `server.url`; never hard-code a port.
- **Stop the server in `tearDown`.** Call `stop()` once per server.

## Seed files (YAML or JSON)

```yaml
version: 1
data:
  User:                 # keyed by OpenAPI schema name
    - id: user-1
      name: Avery Quinn
      email: avery@example.com
  Cart:
    - id: cart-1
      owner: user-1     # Cart.owner is User-typed in the spec → stored as a reference,
      items: []         # served as the embedded record
```

Without a spec, add a `resources:` block (or `Resource("tasks")` in the DSL) to name the
collections; see the format reference linked below.

## Testing unhappy paths

```swift
await server.failNext(status: 503)            // the next matched request fails; then normal
await server.failNext(status: 500, count: 3)  // the next three

// Latency and auth are options at start:
try await MockRESTServer.start(spec: .file(specPath), options: .delay(.milliseconds(400)))
try await MockRESTServer.start(spec: .file(specPath), options: .bearer(validTokens: ["good-token"]))
```

With `.bearer`, a request without one of the valid tokens gets `401`.

## What the server answers on its own

| Situation | Response |
|---|---|
| Create on a collection | `201` with a `Location` header |
| Unknown id | `404`, with a "did you mean" hint when an id is close |
| Create with an id that exists | `409` |
| Body that violates the schema | `422` with one entry per offending field path |
| `Accept` that excludes JSON | `406` |
| Missing or invalid bearer token (when configured) | `401` |
| CORS preflight | answered permissively, for localhost web clients |

## Startup errors → fixes

MockREST validates the spec, the seed, generator bindings, and endpoint templates **before**
the port binds, and every error names a document path. Read the path first.

| Error mentions | Fix |
|---|---|
| a path like `paths./users/{id}.get…` and "not supported" | The spec uses a construct outside v1 scope (`allOf`, an external `$ref`, a non-JSON request body). See "Scope" in the README for the rewrite. |
| `data.User[0].emial` … "Did you mean 'email'?" | A seed field the schema does not declare — fix the typo, or declare the property. |
| a dangling reference | The seed references an id no record has. Seed that record explicitly; a schema `example` is not enough. |
| "Cannot read" with a file path | A relative `.file(...)` path — resolve it from the bundle (above). |
| an unknown generator key | Generator keys are `"Schema.field"` (or `"resource.field"` without a spec); the schema or field name is misspelled. |

## Verify your integration

1. Run one test and confirm it reaches `XCUIApplication().launch()` — a thrown `start` means a
   spec or seed problem, and the message says where.
2. While paused at a breakpoint: `curl http://127.0.0.1:PORT/health` answers `ok`, and
   `curl http://127.0.0.1:PORT/<a collection path>` returns the seeded records.
3. A request to a path the spec does not declare returns a `404` that names what is
   registered — use it to spot base-URL or path-prefix mistakes in the app.

## Reference

- [README](https://github.com/AlexNachbaur/mockrest-swift/blob/main/README.md) — overview,
  scope, and known limitations.
- [REST format specification](https://github.com/AlexNachbaur/mockrest-swift/blob/main/docs/design/rest-format.md)
  — spec ingestion, the seed format, and CRUD semantics in full.
- Serving GraphQL from the same port: register `MockRESTEngine` and MockQL's `MockQLEngine` on
  one `MockHost` with a shared `StateStore` — see "One port with GraphQL" in the README.
