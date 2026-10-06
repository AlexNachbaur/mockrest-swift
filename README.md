# MockREST

[![Build](https://github.com/AlexNachbaur/mockrest-swift/actions/workflows/build.yml/badge.svg)](https://github.com/AlexNachbaur/mockrest-swift/actions/workflows/build.yml)
[![Swift 6.3](https://img.shields.io/badge/Swift-6.3-orange.svg)](https://swift.org)
[![Platforms](https://img.shields.io/badge/Platforms-macOS%20%7C%20iOS%20%7C%20Linux%20%7C%20Windows%20%7C%20Android-blue.svg)](#requirements)
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
    spec: .file(specPath),      // OpenAPI 3.0/3.1, YAML or JSON
    seed: .file(seedPath)       // validated against the spec at startup
) {
    // Hand-written endpoints add to — or override — the auto-wired behavior.
    Post("/users/{userId}/verify") { req, state in
        state.update("User", id: req.pathParam("userId")) { $0["verified"] = true }
        return .ok(state["User", id: req.pathParam("userId")])
    }
}

app.launchEnvironment["API_BASE_URL"] = server.url.absoluteString
```

That's a complete backend: every `GET`, `POST`, `PUT`, `PATCH`, and `DELETE` operation in the
spec answers (and `HEAD` wherever `GET` does), collections are CRUD-able and stateful, and
anything the seed doesn't pin down is generated deterministically.

`MockRESTServer.start` can be awaited straight from a `@MainActor` test method — an XCUITest
`setUp`, for instance — and the block takes ordinary `if`/`else`, `switch`, and `for`.

### Locating spec and seed files

`.file(...)` takes a filesystem path, and a relative one is resolved against the **process's
working directory** — which, for a test bundle, is rarely your project folder. Bundle the files
as test resources and build an absolute path instead:

```swift
// SwiftPM test target — declare `resources: [.copy("Fixtures")]` on the target in Package.swift.
let specPath = try #require(
    Bundle.module.path(forResource: "api", ofType: "yaml", inDirectory: "Fixtures"))

// Xcode UI-test bundle — add the files to the UI-test target's "Copy Bundle Resources" phase.
// (`Bundle.main` is the test runner here, not your bundle.)
let specPath = try XCTUnwrap(
    Bundle(for: MyAppUITests.self).path(forResource: "api", ofType: "yaml"))
```

A file that cannot be read fails `start` with an error naming the path that was tried.
`.yaml(...)` and `.json(...)` take the document inline when a fixture is small enough to live
next to the test.

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
let server = try await MockRESTServer.start(spec: .file(specPath))
```

**DSL-only** — no spec at all; state is named resource collections:

```swift
let server = try await MockRESTServer.start {
    Resource("tasks", idField: "taskId")          // enables auto-CRUD at /tasks
    Get("/ping") { _, _ in .ok(["pong": true]) }
}
```

**Both** — the spec defines the surface; DSL endpoints override specific routes (a matching
method + path replaces the auto-wired handler, whatever the endpoint names its path
parameters).

In DSL-only mode, generators are keyed by resource — `generators: ["tasks.assignee": .email]`
fills `assignee` on every task that doesn't store one. With a spec they are keyed by schema
(`"User.email"`).

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

- **Swift 6.3+** (strict concurrency).
- Apple platforms: macOS 14+ / iOS 17+ (minimums exist only for Swift concurrency APIs).
- macOS, iOS, Linux, Windows, and Android are all supported, and CI builds and tests both
  products on every one of them.
- `MockRESTCore` has no networking dependency, so it is also usable in-process on any host that
  cannot or does not want to run a listener.

### Scope notes (v1)

- OpenAPI **3.0.x and 3.1.x**; Swagger 2.0 is rejected with guidance (convert upstream).
- Internal `$ref`s only — into `components.schemas`, `parameters`, `requestBodies`, and
  `responses`. External and remote refs fail with a clear error.
- JSON request/response bodies only (`406` for other `Accept` types); form/multipart are a
  later milestone. A non-JSON body still reaches a hand-written endpoint, as a string.
- Cookie parameters are accepted and ignored. Required query and header parameters are
  enforced (`400`).
- Objects that declare `properties` reject unknown keys unless the schema sets
  `additionalProperties` — that strictness is what turns a seed or request typo into a
  "did you mean". `type: object` with no `properties` is free-form.

MockREST fails loudly rather than guessing, so **one unsupported construct anywhere in the
spec stops the whole spec from loading**. These are the constructs that do, each with an error
naming the document path:

| Construct | What to do |
|---|---|
| `allOf` | Flatten the schema. |
| `oneOf`/`anyOf` with an inline variant | Move the variant to `components.schemas` and `$ref` it. |
| A `requestBody` with no `application/json` content (multipart, form, XML) | Add a JSON alternative, or drop the body from the mocked spec and handle the route with a DSL endpoint. |
| `type: [a, b]` with more than one non-null type | Pick one, or leave `type` off. |
| An external `$ref` (`other.yaml#/…`, a URL) | Bundle the spec into one file first. |
| Swagger 2.0 | Convert to OpenAPI 3 (e.g. with swagger2openapi). |

### Known limitations

Behavior that is narrower than you might expect, and not yet fixed:

- **`enum` is enforced only for strings.** An `enum` on an integer or number schema is ignored:
  any integer passes validation, and generated values are not drawn from the list.
- **A seed cannot reference a record that exists only as a schema `example`.** Example records
  are added after the seed is validated, so `owner: example-user` is reported as a dangling
  reference. Seed the record explicitly.
- **Auto-CRUD routes use fixed status codes and ignore operation examples.** A create is always
  `201` and every other success `200`/`204`, whatever the spec declares (a `202`, say), and a
  response `example` on a collection route is not served — the stored record is.
- **`2XX`-style range keys in `responses` are not recognized,** so an operation that declares
  only `2XX` is treated as having no success response. A `head:` operation in the spec is
  ignored; `HEAD` is answered from the `GET` operation instead.
- **Filters only see stored values.** `?status=active` does not match a record whose `status`
  was filled by a generator at read time. Seed the fields you filter on.
- **An id containing a colon can be misread as a qualified reference.** Where a field holds a
  reference, `User:42` means "the `User` with id `42`" whenever the text before the first colon
  names an object schema. Avoid `Schema:`-prefixed ids.
- **Literal path segments are compared without percent-decoding.** A request for
  `/caf%C3%A9` does not match a route declared as `/café`; parameter values *are* decoded.
- **Call `stop()` once.** With mockcore-swift 0.1.2 and earlier, a second `stop()` on the same
  server never returns.

## Documentation

- [API documentation](https://swiftpackageindex.com/AlexNachbaur/mockrest-swift/documentation) (DocC)
- [docs/design/rest-format.md](docs/design/rest-format.md) — the spec-ingestion, state, and
  endpoint model
- [docs/design/architecture.md](docs/design/architecture.md) — the MockCore platform
  architecture

### For AI coding agents

If an AI agent is wiring MockREST into your test suite, point it at the
[agent integration guide](docs/agents/integration-guide.md) — a self-contained document with
the canonical XCUITest pattern, the rules that prevent the common failures, and an error→fix
table. [llms.txt](llms.txt) indexes it alongside the rest of the documentation. Agents
contributing to MockREST itself should read [AGENTS.md](AGENTS.md).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Security reports: [SECURITY.md](SECURITY.md).

## License

MIT — see [LICENSE](LICENSE).
