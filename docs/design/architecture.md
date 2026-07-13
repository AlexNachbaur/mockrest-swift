# MockCore Platform Architecture

> Status: **Design draft for review.** Nothing here is built yet. Sections marked
> **[OPEN]** need a decision before implementation.

## 1. Goal

Provide a family of native-Swift mocking servers for local UI-test automation that share one
in-memory backend, one data-generation system, and one HTTP listener — so a single test process
can present a virtual server that answers **both** REST and GraphQL (and, later, other
protocols) on one port, while each protocol ships as an independent, separately-adoptable
package.

MockQL already exists and is pre-1.0. MockREST is new. Rather than duplicate MockQL's
transport, state store, generators, and diagnostics, we extract the protocol-neutral parts into
a shared foundation, **MockCore**, that both build on and that any future mock extension can
build on too.

### Design principles (inherited from MockQL, restated for the platform)

1. **Developer experience first.** Ergonomic, expressive, `ResultBuilder`-based APIs.
2. **Error messages are a product feature.** Precise source locations/paths, "did you mean"
   suggestions, fail-fast validation before the server accepts connections.
3. **Swift best practices.** Swift 6 strict concurrency, `Sendable` correctness, small focused
   types, doc comments on all public API, value types over reference types.
4. **Everything is unit-tested; the full stack is integration-tested** over real HTTP.
5. **Fail loud and early.** Specs and seeds are fully validated at load.
6. **MockCore is an extension platform.** REST and GraphQL are the first two extensions, not
   the whole design. The public seam (`MockService`) must let a third party add a new mockable
   protocol without changes to MockCore.

## 2. Package topology

Three (initially) independent packages, plus the consumer's test target:

```
                     ┌─────────────────────────────┐
                     │        mockcore-swift        │
                     │  MockCore         (portable) │  value model, state store,
                     │  MockCoreTransport (NIO)     │  generators, seeded RNG, seed
                     └──────────────┬───────────────┘  primitives, diagnostics,
                                    │                   MockHost + MockService
                 ┌──────────────────┼──────────────────┐
                 │                  │                  ...  (future extensions:
        ┌────────▼────────┐ ┌───────▼─────────┐             gRPC, SOAP, WS-RPC)
        │  mockql-swift    │ │ mockrest-swift  │
        │  MockQLCore      │ │ MockRESTCore    │
        │  MockQL          │ │ MockREST        │
        └────────┬─────────┘ └───────┬─────────┘
                 │                    │
                 └─────────┬──────────┘
                           │  (test target depends on the extensions it needs;
                    ┌──────▼───────┐   extensions never depend on each other)
                    │  MyAppUITests │
                    └───────────────┘
```

Key property: **no extension package depends on any other extension package.** They are siblings
that only share MockCore. Composition happens in the consumer's test target, which links
whichever extensions it wants and registers them on one `MockHost`.

### Module layout

**`mockcore-swift`**
- `MockCore` — pure portable Swift (Yams only; **never imports NIO**):
  - `MockValue` — the protocol-neutral dynamic value type (see §4).
  - `StateStore` / `MutationState` / `StoreData` — the in-memory backend.
  - `FieldGenerator`, `GeneratorContext`, `GeneratorRegistry`, built-in presets.
  - `RandomSource` — seeded deterministic RNG.
  - Seed primitives shared by extensions (value decoding from YAML/JSON, reference model).
  - Diagnostics: `SourceLocation`, `Suggestion`, and a `MockError` base carrying category +
    location + suggestions.
- `MockCoreTransport` — SwiftNIO transport (module name provisional):
  - `MockHost` — the HTTP(/WebSocket) listener; binds a port, owns the NIO event loop group,
    dispatches each request to the first `MockService` that claims it.
  - `MockService` — the extension seam (see §3).
  - `MockRequest` / `MockResponse` — the neutral request/response the host hands to services.

**`mockql-swift`** (refactored) — `MockQLCore`, `MockQL`. `MockQLEngine` conforms to
`MockService`. Public API preserved (see `extraction-plan.md`).

**`mockrest-swift`** (new) — `MockRESTCore`, `MockREST`. `MockRESTEngine` conforms to
`MockService`.

## 3. The extension seam: `MockService`

The whole platform hinges on one protocol. A mock extension is anything that can (a) say whether
it wants to handle an incoming request and (b) produce a response, sharing the MockCore state
store and generators.

```swift
/// A mockable protocol handler that a `MockHost` can serve. REST and GraphQL are the first two;
/// any transport that maps to HTTP (or a host-provided upgrade) can conform.
public protocol MockService: Sendable {
    /// Human-readable name for diagnostics and startup logging (e.g. "MockREST").
    var name: String { get }

    /// Whether this service claims the request. The host asks registered services in
    /// registration order and routes to the first match. Returning a specificity lets the host
    /// break ties deterministically.  [OPEN: bool vs. specificity score — see §7]
    func claims(_ request: MockRequest) -> Bool

    /// Produce a response for a claimed request.
    func respond(to request: MockRequest) async -> MockResponse

    /// Optional: participate in the WebSocket upgrade handshake (GraphQL subscriptions use this;
    /// REST does not).  [OPEN: exact shape of the upgrade hook]
    func webSocketUpgrade(for request: MockRequest) -> MockWebSocketUpgrade?

    /// Called once when the host is about to start accepting connections. Extensions do
    /// fail-fast validation here (or earlier, at construction).
    func willStart() async throws

    /// Called on host shutdown to release resources / end streams.
    func shutdown() async
}
```

- **Routing model.** `MockHost` holds an ordered list of services. For each request it calls
  `claims(_:)` in order and dispatches to the first that returns true; if none claim it, the host
  returns a 404 with a diagnostic listing the registered services and, where cheap, near-miss
  suggestions. GraphQL claims `POST/GET /graphql`; REST claims everything else (or, more
  precisely, the routes its spec/DSL defines). Registration order therefore matters and is the
  user's lever — documented, not magic.
- **Shared state.** Services are constructed with (or given access to) a shared `StateStore` and
  `GeneratorRegistry` so a mutation performed via REST is visible to a subsequent GraphQL query
  and vice-versa. **[OPEN, §7]:** default to one shared store across all services, with an opt-in
  to isolate a service's store.
- **One port.** The host owns the socket; services never bind their own. This is what makes the
  "single virtual server" real.

### Composition entry point

```swift
let server = try await MockHost.start(port: 0) {           // 0 → ephemeral port
    MockREST(spec: .file("api.yaml"), seed: .file("world.yaml"))
    MockGraphQL(schema: .file("shop.graphqls"))
}
app.launchEnvironment["API_BASE_URL"] = server.url.absoluteString   // one URL, both protocols
```

`MockHost.start` takes a result-builder of `MockService`s. Each extension also keeps its own
standalone `start` (e.g. `MockRESTServer.start(...)`) that wraps a single-service `MockHost`, so
adopting just one extension stays a one-liner and matches MockQL's current
`MockQLServer.start(...)` ergonomics.

## 4. The neutral value model

MockQL's `GraphQLValue` is already 8/9 protocol-neutral. Its cases: `null, bool, int, double,
string, enumValue, list, object, reference(type,id)`. Only `enumValue` reads as GraphQL-specific
— and OpenAPI schemas have enums too, so it generalizes cleanly.

**Plan:** move the type into `MockCore` as `MockValue`, unchanged in shape (all the literal
conformances, subscripts, `append`, `??`, `CustomStringConvertible`). MockQL keeps
`public typealias GraphQLValue = MockValue`, preserving source compatibility for every existing
consumer and test. REST uses `MockValue` directly.

`reference(type, id:)` stays in the neutral model: it's a store concept ("this field points at
record X"), not a GraphQL concept. Schema-driven reference *resolution* rules (what a bare string
in a typed position means) live in each extension, since they depend on that extension's schema.

## 5. State, generators, seeding (shared)

- `StateStore` (an actor) and `MutationState` (transactional writes committed atomically) move to
  MockCore verbatim — they already speak only `MockValue` + `type`/`id` strings.
- `FieldGenerator`/`GeneratorContext`/`RandomSource` move verbatim; generators are keyed by
  `"Type.field"` today. Extensions supply the "Type" namespace (GraphQL type name; REST schema or
  resource name).
- **Seed primitives** shared: YAML/JSON → `MockValue` decoding, duplicate-id detection, the
  reference-string model, generator fill-in of omitted fields with lifetime-stable values,
  `null`-pinning. **Schema-specific validation** (does this field exist on this type? is this enum
  member valid?) stays in each extension, driven by its own schema model. The REST seed format is
  specified in `rest-format.md`.

## 6. Dependencies, platforms, licensing

Inherited from MockQL and applied platform-wide:

- **Toolchain:** Swift 6.1, strict concurrency. `Package.swift` declares Apple minimums
  (macOS 14 / iOS 17) only for concurrency availability; Linux/Windows/Android unaffected.
- **Dependencies:** Yams (YAML) in `MockCore`; SwiftNIO in `MockCoreTransport`. `MockCore` is
  NIO-free and portable (usable where NIO isn't, e.g. Windows, via in-process execution).
  MockREST's OpenAPI ingestion is **hand-rolled Codable + validation** — no new dependency (see
  `rest-format.md`). No other dependencies without asking.
- **License:** MIT, open source under `github.com/AlexNachbaur/*`.
- **swift-format** enforced (120 cols, 4-space), no force unwraps, no `DispatchQueue`.

## 7. Open decisions

All platform-level items were **decided with the project owner on 2026-07-12**:

1. **`MockCoreTransport` module name** — ✅ decided: keep `MockCoreTransport` as a separate
   module so `MockCore` stays NIO-free.
2. **`claims(_:)` return type** — ✅ decided: `Bool`, first-match-wins in registration order
   (documented, deterministic). Revisit only if real conflicts appear pre-1.0.
3. **Shared vs. isolated state store** — ✅ decided: one shared `StateStore` across all services
   by default (enables cross-protocol flows), with a per-service opt-out.
4. **WebSocket upgrade hook shape** — ✅ decided: design the seam now — an optional `MockService`
   requirement with a default `nil` implementation; REST ignores it, no GraphQL special-casing
   in `MockHost`.
5. **Repo bootstrapping order** — ✅ decided: develop mockcore/mockql/mockrest against local
   path dependencies until MockCore is tagged (extraction-plan Phase 0/3).
