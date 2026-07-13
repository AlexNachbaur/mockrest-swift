# MockREST

A native-Swift REST API mocking server for local UI-test automation (XCUITest first), built on
the [MockCore](https://github.com/AlexNachbaur/mockcore-swift) platform. Define the API with an
**OpenAPI 3.0/3.1 spec**, a **Swift result-builder DSL**, or both — MockREST serves stateful,
deterministic JSON over a real localhost HTTP server.

```swift
let server = try await MockRESTServer.start(
    spec: .file("Schemas/api.yaml"),
    seed: .file("Fixtures/world.yaml")
) {
    // Hand-written endpoints add to — or override — the auto-wired behavior.
    Post("/users/{userId}/verify") { req, state in
        state.update("User", id: req.pathParam("userId")) { $0["verified"] = true }
        return .ok(state["User", id: req.pathParam("userId")])
    }
}
app.launchEnvironment["API_BASE_URL"] = server.url.absoluteString
```

## What you get

- **Auto-CRUD** for every resource collection (from the spec's paths or a `resources:`
  declaration): list with `?field=` filtering, `?sort=`, and `limit`/`offset` pagination
  (envelope shapes synthesized when the spec declares one), fetch/create/replace/merge/delete
  with correct statuses (`201 + Location`, `404`, `409`, `422` with field-path diagnostics).
- **Spec-driven state**: `components.schemas` are the type system. Seeds are validated against
  them — unknown fields, enum typos, duplicate ids, and dangling references fail at startup
  with "did you mean" suggestions, never mid-test.
- **Deterministic data generation**: omitted fields are filled by generators (names, emails,
  timestamps, …) and stay stable for the server's lifetime; equal `serverSeed`s generate equal
  worlds.
- **References that embed**: `owner: user-1` in a `User`-typed field stores a reference and
  serializes as the full record.
- **Test controls**: `failNext(status:)` fault injection, `.delay(_)` latency, bearer-token
  auth simulation, permissive CORS for localhost web clients.
- **One port, many protocols**: `MockRESTEngine` is a MockCore `MockService` — register it on a
  `MockHost` next to [MockQL](https://github.com/AlexNachbaur/mockql-swift) and a REST mutation
  is instantly visible to GraphQL queries (they share one state store).

## Modules

- **`MockRESTCore`** — the portable engine (no networking): spec ingestion, seeds, routing,
  CRUD, synthesis. Runs anywhere Swift runs.
- **`MockREST`** — the `MockService` conformance and the `MockRESTServer` facade (SwiftNIO via
  `MockCoreTransport`).

## Status

Pre-1.0, in active development. See `docs/design/` for the architecture and format
specifications.

## License

MIT — see [LICENSE](LICENSE).
