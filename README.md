# MockREST

[![Build](https://github.com/AlexNachbaur/mockrest-swift/actions/workflows/build.yml/badge.svg)](https://github.com/AlexNachbaur/mockrest-swift/actions/workflows/build.yml)
[![Swift 6.1](https://img.shields.io/badge/Swift-6.1-orange.svg)](https://swift.org)
[![Platforms](https://img.shields.io/badge/Platforms-macOS%20%7C%20iOS%20%7C%20Linux%20%7C%20Android-blue.svg)](#requirements)
[![License: MIT](https://img.shields.io/badge/License-MIT-lightgrey.svg)](LICENSE)

A native Swift REST API mocking server for local UI-test automation.

MockREST runs a lightweight, stateful REST server alongside your tests so your app can talk to
a real backend — one you fully control from Swift, with no fixtures folder full of brittle JSON
files and no network flakiness. Point it at your **OpenAPI spec** and it mocks the whole
surface; add **Swift closures** for the endpoints that need custom behavior; seed the world
from **validated YAML/JSON**. Built for XCUITest first, but the engine runs anywhere Swift
does.

> **Status: pre-1.0.** Everything shown below — OpenAPI 3.0/3.1 ingestion, auto-CRUD, seeds,
> deterministic generation, the endpoint DSL, fault injection, auth simulation, CORS — is
> implemented and covered by unit and integration tests. The API may still evolve before
> `1.0.0`; breaking changes are called out in the [CHANGELOG](CHANGELOG.md).

## Quick start

```swift
import MockREST

let server = try await MockRESTServer.start(
    spec: .file("Schemas/api.yaml"),      // OpenAPI 3.0/3.1, YAML or JSON
    seed: .file("Fixtures/world.yaml")    // validated against the spec at startup
) {
    // Hand-written endpoints add to — or override — the auto-wired behavior.
    Post("/users/{userId}/verify") { req, state in
        state.update("User", id: req.pathParam("userId")) { $0["verified"] = true }
        return .ok(state["User", id: req.pathParam("userId")])
    }
}

app.launchEnvironment["API_BASE_URL"] = server.url.absoluteString
```

That's a complete backend: every path in the spec answers, collections are CRUD-able and
stateful, and anything the seed doesn't pin down is generated deterministically.

## Why MockREST?

UI tests that hit live backends are slow and flaky. UI tests that stub the network layer with
canned JSON rot quickly — every API change means hand-editing fixtures, and stateless stubs
can't model flows like "create an account, then see it on the profile screen."

- **Your spec is the source of truth.** `components.schemas` are the type system: seeds and
  request bodies are validated against them, responses are shaped by them.
- **Auto-CRUD** for every resource collection: list with `?field=value` filtering,
  `?sort=field`/`?sort=-field`, and `limit`/`offset` pagination (envelope shapes synthesized
  when the spec declares one), plus create/replace/merge/delete with real-world semantics —
  `201` + `Location`, `404` for missing ids (with "did you mean" hints), `409` on id conflicts,
  `422` with field paths for invalid bodies.
- **Stateful by design** — a `POST` in step one is visible to every `GET` that follows.
  Handlers run against a transactional store: writes commit atomically when the closure
  returns.
- **Deterministic data generation** — omitted fields are filled with realistic names, emails,
  phone numbers, UUIDs, timestamps…, stable per record + field and reproducible via
  `serverSeed`.
- **References that embed** — `owner: user-1` in a `User`-typed field stores a reference and
  serializes as the full record, exactly like MockQL seeds.
- **Fail loud and early.** Specs, seeds, generator bindings, and endpoint templates are all
  validated before the port binds. Diagnostics carry document paths
  (`paths./users/{id}.get.responses.200`, `data.User[0].email`) and typo suggestions.
- **Test the unhappy paths** — `server.failNext(status: 503)` forces failures for error-UI
  tests, `.delay(_)` exercises loading states, `.bearer(validTokens:)` simulates auth (401),
  and CORS preflights answer permissively for localhost web clients.

## Three ways to define an API

**Spec-only** — zero closures for a conventional API:

```swift
let server = try await MockRESTServer.start(spec: .file("api.yaml"))
```

**DSL-only** — no spec at all; state is named resource collections:

```swift
let server = try await MockRESTServer.start {
    Resource("tasks", idField: "taskId")          // enables auto-CRUD at /tasks
    Get("/ping") { _, _ in .ok(["pong": true]) }
}
```

**Both** — the spec defines the surface; DSL endpoints override specific routes (a matching
method + path replaces the auto-wired handler).

## Seeding

The seed format mirrors MockQL's (`version` / `data`), with a `resources:` block to wire
collections when there's no spec to infer them from:

```yaml
version: 1
data:
  User:
    - id: user-1
      name: Avery Quinn
      email: avery@example.com     # omitted fields (phone, …) are generated & stable
  Cart:
    - id: cart-1
      owner: user-1                # Cart.owner is User-typed → a reference
      items: []
```

Schema-level `example`s in the spec seed a starting world for any schema you don't seed
explicitly — explicit seeds always win.

## One port with GraphQL

`MockRESTEngine` is a [MockCore](https://github.com/AlexNachbaur/mockcore-swift) `MockService`.
Register it on a shared `MockHost` next to
[MockQL](https://github.com/AlexNachbaur/mockql-swift) with one shared `StateStore`, and a REST
mutation is instantly visible to a GraphQL query (and vice versa):

```swift
let store = StateStore()
let host = try await MockHost.start {
    try await MockRESTEngine(spec: .file("api.yaml"), seed: .file("world.yaml"), store: store)
    try await MockQLEngine(schema: .file("shop.graphqls"), store: store)
}
```

## Installation

Add MockREST to your test target (it's a test tool — your app never links it):

```swift
dependencies: [
    .package(url: "https://github.com/AlexNachbaur/mockrest-swift.git", from: "0.1.0")
],
targets: [
    .testTarget(name: "MyAppUITests", dependencies: [
        .product(name: "MockREST", package: "mockrest-swift")
    ])
]
```

Use the `MockRESTCore` product instead for in-process execution with no server (no SwiftNIO).

## Requirements

- **Swift 6.1+** (strict concurrency).
- Apple platforms: macOS 14+ / iOS 17+ (minimums exist only for Swift concurrency APIs).
- Linux and Android are fully supported and exercised in CI; `MockRESTCore` also builds where
  SwiftNIO isn't available (e.g. Windows).

### Scope notes (v1)

- OpenAPI **3.0.x and 3.1.x**; Swagger 2.0 is rejected with guidance (convert upstream).
- Internal `#/components/schemas/…` `$ref`s only; external refs and `allOf` fail with clear
  errors.
- JSON request/response bodies only (`406` for other `Accept` types); form/multipart are a
  later milestone.

## Documentation

- [API documentation](https://swiftpackageindex.com/AlexNachbaur/mockrest-swift/documentation) (DocC)
- [docs/design/rest-format.md](docs/design/rest-format.md) — the spec-ingestion, state, and
  endpoint model
- [docs/design/architecture.md](docs/design/architecture.md) — the MockCore platform
  architecture

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Security reports: [SECURITY.md](SECURITY.md).

## License

MIT — see [LICENSE](LICENSE).
