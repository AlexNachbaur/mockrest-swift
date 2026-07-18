# MockREST — Spec Ingestion, State & Endpoint Model

> Status: **Design draft for review.** Sections marked **[OPEN]** need a decision before
> implementation. Depends on the platform design in `architecture.md`.

MockREST is the REST extension of the MockCore platform (`MockRESTCore` = portable engine,
`MockREST` = the `MockService` + facade). It mocks a stateful REST backend for UI tests, defined
by an **OpenAPI spec**, a **Swift DSL**, or both together.

## 1. Two ways to define an API (composable)

```swift
// (a) From an OpenAPI spec — every path becomes mockable; schemas drive generation & validation.
let server = try await MockRESTServer.start(
    spec: .file("Schemas/api.yaml"),
    seed: .file("Fixtures/world.yaml")
) {
    // (b) Hand-added / overriding endpoints, as Swift closures over shared state.
    Post("/users/{id}/verify") { req, state in
        state.update("User", id: req.pathParam("id")) { $0["verified"] = true }
        return .ok(state["User", id: req.pathParam("id")])
    }
}
```

- **Spec-only** works with zero closures for a conventional API (auto-CRUD, §5).
- **DSL-only** works with no spec at all — declare endpoints and their responses inline; state is
  modeled as resource collections (§3).
- **Both**: the spec defines the surface and schemas; DSL endpoints add or override behavior. A
  DSL endpoint whose method+path matches a spec operation replaces the auto-wired handler.

## 2. OpenAPI ingestion (hand-rolled Codable + validation)

- **Versions:** OpenAPI **3.0.x and 3.1.x**. Swagger 2.0 is **[OPEN]** — recommend out of scope
  for v1 (convertible upstream). 3.1 aligns with JSON Schema 2020-12; 3.0 has its own subset — we
  normalize both into one internal `RESTSchema` model.
- **Parsing:** the spec is JSON or YAML, so this is a **decoder + validator**, not a
  character-level parser. We decode with `Codable` (Yams for YAML, Foundation for JSON) into typed
  models, then validate. This honors the platform's "hand-written for diagnostics + portability,
  no heavy deps" rule without the cost of a real grammar parser.
- **What we consume:** `paths` → operations (method, `parameters`, `requestBody`, `responses`),
  `components.schemas`, and `example`/`examples`. `$ref`s into
  `components.parameters/requestBodies/responses` are rejected with clear "not supported in v1"
  errors — inline those definitions.
  `$ref` is resolved (internal refs for v1; **[OPEN]** external/remote refs — recommend
  unsupported-with-clear-error for v1). `servers`, `security` schemes → see §8.
- **Diagnostics:** unknown `$ref` targets, schemas referencing missing components, malformed
  parameter definitions, and (against a seed) type mismatches all fail fast with the JSON/YAML
  path (`paths./users/{id}.get.responses.200`) and "did you mean" suggestions, mirroring MockQL's
  seed diagnostics.

## 3. State model — schema-driven when a spec exists

Following the settled decision: **when a spec is loaded, `components.schemas` are the type
system** (the REST analogue of GraphQL object types); **without a spec, state is modeled as named
resource collections.** Either way, state lives in the shared MockCore `StateStore` as records
(`MockValue` trees) grouped by a type name and keyed by id.

- **Records & ids.** Each stored record has an `id` (string; ints coerce to string ids as in
  MockQL). The id field name defaults to `id` and is **[OPEN]**: configurable per resource
  (`userId`, `uuid`) — recommend a per-resource `idField` override, default `"id"`.
- **References are schema-driven.** A string in a field whose schema type is another object schema
  is a reference to that record's id (`Cart.owner: User` → `owner: "user-1"`). A string in a
  scalar field is a literal. For `oneOf`/`anyOf` (union-ish) positions, use the qualified
  `Schema:id` form so the concrete type is known — same rule as MockQL interfaces/unions.
- **Embedded objects.** A nested map is an anonymous embedded value object (e.g. an inline
  `Address`), not a reference.
- **Omitted fields are generated and stable.** Any schema field not present in the seed is filled
  by its configured generator (or a type-appropriate default from the schema: `format: email` →
  email, `format: uuid` → uuid, `format: date-time` → timestamp, enum → a member, etc.) and the
  value stays stable for the server's lifetime. `field: null` pins an explicit null (nullable
  fields only).
- **Generators** are keyed `"Schema.field"` when spec-driven (`"User.email": .email`) and
  `"resource.field"` in DSL-only mode. Schema `format`/`pattern`/`enum` inform default generator
  selection.

### Seed format (v1)

Mirrors MockQL's `version` / `data` / `roots` with REST-appropriate wiring:

```yaml
version: 1
data:                       # records grouped by schema (or resource) name
  User:
    - id: user-1
      name: Avery Quinn
      email: avery@example.com   # omitted fields (phone, …) generated & stable
  Product:
    - id: product-1
      name: Espresso Machine
      priceCents: 64900
  Cart:
    - id: cart-1
      owner: user-1         # Cart.owner typed User → reference
      items: []

resources:                  # [OPEN name] wires collections to their base paths
  users:    { schema: User,    path: /users }
  products: { schema: Product, path: /products }
  carts:    { schema: Cart,    path: /carts }
```

- The `resources:` block (name **[OPEN]** — `resources` vs `routes` vs `collections`) is what
  makes a collection addressable and enables auto-CRUD (§5). When a spec is present, MockREST can
  infer most of this from paths + response schemas, so `resources:` becomes optional/override.
- **[OPEN]** OpenAPI `example`/`examples` as an implicit seed source: recommend spec examples seed
  state only when no `data:` is provided for that schema (explicit seed always wins), so examples
  give a zero-config starting world but never fight an author's fixtures.

## 4. Request matching

The host hands MockREST a `MockRequest` (method, path, query, headers, body as `MockValue`).
MockREST matches against its route table:

- **Path templates** `/users/{id}` extract path params. `req.pathParam("id")` reads them.
- **Precedence:** exact/static segments beat templated segments (`/users/me` before
  `/users/{id}`); longer/more-specific patterns win ties. Deterministic and documented.
- **Query params** (`?limit=20&sort=name`) are parsed into `req.query`.
- **Content negotiation:** JSON is the default and only guaranteed content type for v1. `Accept`
  is honored where a route offers alternatives; unsupported types → 406. **[OPEN]:** non-JSON
  bodies (form-urlencoded, multipart, XML) — recommend JSON-only v1, form/multipart as a later
  milestone.
- **`claims(_:)`** returns true when the method+path matches a known route. Unmatched requests
  fall through so another service (or the host's 404) handles them — important for REST+GraphQL
  coexistence where GraphQL owns `/graphql`.

## 5. CRUD auto-wiring (hybrid: auto + override)

For each resource collection (from spec or `resources:`), MockREST auto-implements conventional
CRUD against the shared store, all overridable by a DSL endpoint of the same method+path:

| Method & path            | Behavior                                                        | Success |
|--------------------------|----------------------------------------------------------------|---------|
| `GET /users`             | list; pagination + filter + sort (below)                       | 200     |
| `GET /users/{id}`        | fetch one; missing → 404                                        | 200/404 |
| `POST /users`            | create; generate id if absent; validate against schema         | 201 + `Location` |
| `PUT /users/{id}`        | replace; **[OPEN]** upsert vs 404-if-absent (recommend 404)     | 200     |
| `PATCH /users/{id}`      | merge fields                                                    | 200     |
| `DELETE /users/{id}`     | remove; idempotent                                             | 204     |

- **Pagination [OPEN].** Recommend `limit`/`offset` by default, response shape configurable, and
  when the spec's list response schema is an envelope (e.g. `{data, page, total}`) or a Relay-ish
  connection, synthesize that shape instead — schema-driven, analogous to MockQL's connection
  synthesis. Cursor pagination as an opt-in.
- **Filtering/sorting [OPEN].** Recommend a small convention: `?field=value` filters by equality,
  `?sort=field`/`?sort=-field` sorts. Filters match **stored** values; fields filled by
  generators at read time are not filterable. Kept minimal and documented; complex query
  semantics are a non-goal (this is a test mock, not a query engine).
- **Validation.** POST/PUT/PATCH bodies validate against the request/schema; violations → 422 (or
  400 **[OPEN]**) with field-path diagnostics.
- **Auto-CRUD is opt-in-per-resource, not global** — a resource only gets CRUD if it's declared as
  a collection (or the spec defines those operations). Non-collection schemas (e.g. `Money`) never
  get endpoints.

## 6. Endpoint DSL & responses

```swift
Get("/users/{id}") { req, state in
    guard let user = state.optional("User", id: req.pathParam("id")) else { return .notFound }
    return .ok(user)
}

Post("/orders") { req, state in
    let order = state.create("Order", from: req.body)          // generators fill omitted fields
    return .created(order, location: "/orders/\(order["id"].stringValue ?? "")")
}
```

- **`req`**: method, `pathParam(_:)`, `query`, `headers`, `body` (a `MockValue`).
- **`state`**: the shared MockCore store handle — the same `update`/`create`/subscript surface
  MockQL mutation closures use, so mutation code is portable across protocols.
- **`MockResponse` builders**: `.ok(_)`, `.created(_, location:)`, `.noContent`, `.notFound`,
  `.status(_, body:)`, plus header/content-type control. Bodies are `MockValue`; omitted schema
  fields are generated on the way out.
- **Response synthesis from spec.** For auto-wired endpoints, MockREST picks the response by
  status (2xx by default), builds the body from the response schema + stored record + generators,
  and honors a matching `example` when present.

## 7. Validation & diagnostics (fail-fast, before bind)

At `willStart()` MockREST validates the whole configuration and refuses to start on any error:
unknown `$ref`; seed record for an unknown schema (with suggestions); seed field not in schema;
dangling reference; duplicate id; enum/format/scalar mismatch; a DSL route whose path params
don't appear in its template; circular `$ref` alias chains. (Cross-service path precedence —
e.g. coexisting with GraphQL's `/graphql` — is governed by `MockHost` registration order.)
Every diagnostic
carries the file + JSON/YAML path and, where applicable, a "did you mean".

## 8. Cross-cutting features — proposed scope

Common mock-server capabilities. Recommend v1 vs. later:

- **Auth simulation [OPEN]** — recognize `security` schemes; unauthenticated/expired → 401/403.
  Recommend a lightweight opt-in (`.bearer(validTokens:)`) in v1; full OAuth flows out of scope.
- **Latency & fault injection [OPEN]** — inject delays or force error responses to test loading
  and error UI. Recommend a small v1 API (`.delay(_)`, `.failNext(status:)`), since it's a core
  reason to mock.
- **CORS / preflight** — recommend permissive localhost defaults, configurable.
- **Non-JSON content types** — later milestone (see §4).
- **Recorded-response seeding** — normalize a captured JSON payload into records; a stretch goal,
  parallels MockQL's TODO.

## 9. Open decisions (consolidated)

All items **decided with the project owner on 2026-07-12**:

1. Swagger/OpenAPI 2.0 — ✅ **no** for v1 (convertible upstream).
2. External/remote `$ref` — ✅ **unsupported with a clear error** for v1.
3. Seed block — ✅ named **`resources:`**, inferred from the spec when one is present
   (explicit block overrides inference).
4. Id field — ✅ configurable **`idField`** per resource, default `"id"`.
5. Spec `examples` as implicit seed — ✅ only when no explicit `data:` exists for that schema.
6. Pagination — ✅ `limit`/`offset` default; envelope synthesis when the list response schema
   is an envelope. Cursor pagination deferred.
7. Filtering/sorting — ✅ `?field=value` equality filter, `?sort=field` / `?sort=-field`.
8. CRUD semantics — ✅ PUT replaces only (**404** when absent); body-validation failures →
   **422** with field-path diagnostics (400 stays for malformed syntax).
9. v1 cross-cutting scope — ✅ **all three**: latency + fault injection (`.delay(_)`,
   `failNext(status:)`), bearer auth simulation (`.bearer(validTokens:)` → 401), and
   permissive-localhost CORS/preflight defaults.
10. Non-JSON content types — ✅ later milestone; JSON-only v1 (unsupported `Accept` → 406).
