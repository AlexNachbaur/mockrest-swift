# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this
project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- **`readOnly` properties may be omitted from a request even when `required`.** The nested
  `required` enforcement below would otherwise have rejected the canonical generated-spec
  shape — `id`/`createdAt` listed as both `required` and `readOnly` — on every create, at every
  depth (found in review). The server fills those; OpenAPI says a request may leave them out.
- **Filtering no longer depends on what the store happens to contain.** With a spec, a query
  parameter filters only when it names a schema property. Without one, every parameter filters
  except the paging/sorting vocabulary (`limit`, `offset`, `sort`, `page`, `per_page`,
  `perPage`, `pageSize`, `page_size`) — previously `?status=done` returned everything until
  some record gained a `status`, then nothing, which made the same test pass or fail depending
  on what an earlier step had POSTed.
- A typed `additionalProperties` schema no longer admits `null` for every extra key.
- **A declared non-JSON `Content-Type` is believed.** `text/plain` with a body that opens with
  `[` or `{` reached a handler as a 400 "not valid JSON"; now only an undeclared type, or the
  form-urlencoded default URLSession and curl apply, is judged by the first byte. A body with
  no `Content-Type` that does not open like JSON is passed through as text rather than refused.
- **`MockRESTServer.start { … }` and `MockRESTEngine { … }` now compile from `@MainActor`
  code.** They are `nonisolated(nonsending)`, so the configuration block is evaluated on the
  caller's actor instead of being sent across an isolation boundary. Previously an XCUITest
  `setUp` — the call site this package exists for — was rejected by the compiler with "sending
  value of non-Sendable type".
- **`if`/`else`, `switch`, and `for` now work inside the configuration block.** The builder
  accepted only a flat list of declarations, so the first conditional endpoint failed to
  compile.
- A DSL endpoint or explicit `Resource` now overrides the spec route it shadows **whatever it
  names the path parameter**. `Get("/users/{userId}")` over a spec's `/users/{id}` used to
  leave both routes registered, and an alphabetical tiebreak silently picked the spec's.
- Free-form objects are usable: `type: object` with no `properties` accepts any keys,
  `additionalProperties: true` or a schema accepts (and, for a schema, validates) keys beyond
  `properties`, and `required` may name such a key. Every extra key used to be rejected as an
  unknown field. Objects that declare `properties` and do not opt in stay closed, so seed and
  request typos still get their "did you mean" diagnostic.
- Omitted fields typed by a `$ref` to a scalar, enum, or array schema are generated like the
  schema they name instead of being served as `null`.
- List endpoints no longer treat every unknown query parameter as a filter. `?page=1`,
  `?include=owner`, or a cache-buster used to match no record and return `[]`; a parameter is
  now a filter only when it names a field of the collection.
- Path templates may mix literal text and parameters in one segment (`/files/{name}.json`,
  `/users/{id}:activate`, `/reports/{year}-{month}`); these used to abort spec loading. Two
  parameters with nothing between them (`/a/{x}{y}`) are rejected with a clear error instead of
  being parsed as one parameter named `x}{y`.
- HTTP semantics:
  - the `Bearer` authorization scheme is matched case-insensitively, as RFC 9110 requires;
  - `Accept` is parsed as media ranges (with `q=0` honored) rather than searched for the
    substring "json", and `+json` types are accepted;
  - `HEAD` is answered by the matching `GET` route — same status and headers, no body —
    instead of `405`, and `Allow` advertises it;
  - cross-origin responses carry `Vary: Origin` and `Access-Control-Expose-Headers`, so a
    browser client can read `Location` after a create and caches do not replay one origin's
    answer to another;
  - a request body that is not JSON and does not claim to be reaches hand-written endpoints
    as a `.string` instead of being refused with `400` before routing (malformed JSON is
    still a `400`);
  - a response body that cannot be encoded as JSON (`NaN`, say) is a `500` that says so, not
    an empty `200`;
  - a handler that sets its own `Content-Type` no longer gets a second
    `application/json` header appended.
- References in a response body are resolved inside the handler's transaction, so a response
  is one consistent view of the state the handler saw. A concurrent write could previously
  land between the handler and the embedding of the records it referenced.
- Generators work in DSL-only mode, keyed `"resource.field"` as the format reference always
  said: keys are validated against the declared resources and bound fields are filled on
  records that omit them. They were silently ignored.
- Request validation now reaches all the way down: `required` is enforced on nested objects
  and array elements of POST/PUT bodies, an object in a `oneOf`/`anyOf` position is validated
  against the variant it matches (it was always a `422`), and requests missing a
  `required: true` query or header parameter get a `400` naming it.
- A request whose task is cancelled while waiting out `.delay(_)` no longer runs its handler;
  it returns `503` without touching state.
- The `Location` header of a create percent-encodes ids that are not plain path segments.
- Stored fields the schema does not declare (written by a handler, or by a sibling protocol
  mock sharing the store) are served instead of silently dropped from spec-mode responses.
- `MockRESTVersion.current` reported `0.1.0` in the 0.1.1 release; it now tracks the tag, and
  a test checks it against this file.

### Added

- `$ref`s into `components.parameters`, `components.requestBodies`, and
  `components.responses` are resolved (unknown names get a "did you mean", cycles are
  diagnosed, and errors inside a component point at `components.<section>.<name>`). Specs
  exported by most tools use these, and each one previously aborted the load.
- `in: cookie` parameters are accepted and ignored rather than rejected, so specs that
  declare them load.
- `MockRESTBuilder` gained `buildExpression`, `buildArray`, and `buildLimitedAvailability`.

### Changed

- README gains **Known limitations** and guidance on resolving `.file(...)` paths from a test
  bundle; the scope notes list every construct that still fails spec loading. The format
  reference (`docs/design/rest-format.md`) is updated from design draft to a description of
  what shipped.

## [0.1.1] - 2026-07-27

### Changed

- **Minimum toolchain is now Swift 6.3** (`swift-tools-version: 6.3`, was 6.1). This aligns
  every package in the platform on one toolchain: the Swift SDK for Android starts at 6.3, and
  `securestore-swift` already required it. Consumers on Swift 6.1 or 6.2 must upgrade.
- CI now builds and tests on **macOS, an iOS simulator, Linux, Windows, and an Android
  emulator**. Windows and iOS were previously untested, and iOS is the primary target for
  XCUITest automation.
- **Windows is now fully supported, transport included.** The previous claim that
  `MockRESTCore` existed for "platforms where SwiftNIO is unavailable, such as Windows" was out
  of date — NIOPosix has carried a Windows port since well before 2.101. `MockRESTCore` remains
  the in-process execution path, which is what it is actually useful for.
- The lint job now gates every other job, and the Linux job gates the expensive runners, so a
  formatting or compile failure is caught before macOS/Windows/Android minutes are spent.
- The documentation build no longer runs in CI. `swift package generate-documentation` remains
  a required local pre-commit step (see AGENTS.md and CONTRIBUTING.md).
- Dependabot now watches the `github-actions` ecosystem in addition to `swift`, grouped into a
  single weekly PR.

## [0.1.0] - 2026-07-18

### Fixed

- Resource inference no longer turns literal singleton/RPC paths (`/me`, `/login`,
  `/orders/latest`) into collections: a lone literal path is a collection only when its GET
  response is actually list-shaped. Misinference previously served the whole collection from
  `GET /me` and wired `POST /login` to CRUD-create.
- Circular `$ref` alias chains in a spec are rejected at load with a diagnostic instead of
  overflowing the stack during seed coercion.
- OpenAPI 3.1 nullability is honored for `oneOf`/`anyOf` null variants and for `$ref`s to
  nullable named schemas — explicit `null` seeds and bodies in those positions now validate.
- `failNext(status:)` faults are consumed only by requests that match a route; CORS preflights,
  404s, and 405s no longer eat a queued failure meant for the real call.
- Spec operations without a stored collection behind them now enforce their declared
  `requestBody` schema (422 with field paths) and `required: true` bodies.
- `$ref`s into `components.parameters/requestBodies/responses` fail with clear
  "not supported in v1" errors instead of misleading diagnostics.
- Schema `example`s with integer ids seed correctly (coerced to string ids, matching seeds).
- A non-object JSON body sent to an object-schema `requestBody` is a 422 type error instead of
  being reinterpreted through reference coercion.

### Changed

- Test-only mockql dependency now resolves the tagged `0.2.0` release, so version-based
  consumers of this package resolve cleanly.

### Added

- Initial MockREST implementation on the MockCore platform:
  - OpenAPI 3.0.x/3.1.x ingestion (hand-rolled decoder + validator with document-path
    diagnostics and "did you mean" suggestions; Swagger 2.0 and external `$ref`s rejected with
    clear errors).
  - Resource inference from spec paths, plus explicit `resources:` seed declarations and DSL
    `Resource(...)` declarations (configurable `idField`).
  - Auto-CRUD with filtering (`?field=`), sorting (`?sort=field` / `?sort=-field`),
    `limit`/`offset` pagination, and envelope synthesis; PUT is replace-only (404 when absent);
    body validation returns 422 with field paths.
  - Seed format v1 (`version` / `data` / `resources`) with schema-driven reference resolution,
    embedded value objects, enum validation, duplicate-id and dangling-reference detection.
  - Schema `example`s seed a starting world when no explicit `data:` exists for that schema;
    operation response `example`s win over synthesis.
  - Deterministic response synthesis: omitted fields generated stably per record + field;
    references embed the referenced record.
  - Endpoint DSL (`Get`/`Post`/`Put`/`Patch`/`Delete`) over the shared transactional
    `MutationState`, overriding auto-wired routes.
  - Cross-cutting options: `.delay(_)` latency, `failNext(status:)` fault injection,
    `.bearer(validTokens:)` auth simulation (401), permissive CORS/preflight.
  - `MockRESTEngine: MockService` + `MockRESTServer` facade; cross-protocol integration tests
    prove REST + GraphQL (MockQL) on one `MockHost` with one shared `StateStore`.

[0.1.1]: https://github.com/AlexNachbaur/mockrest-swift/releases/tag/0.1.1
[0.1.0]: https://github.com/AlexNachbaur/mockrest-swift/releases/tag/0.1.0
