# MockREST — Spec Ingestion, State & Endpoint Model

> Status: **Implemented** (shipped in 0.1.0; this document describes the current behavior).
> It began as the design draft; every question it raised was decided on 2026-07-12 and the
> decisions are recorded in §9 — treat them as settled. Built on the platform described in
> `architecture.md`. What is deliberately not handled yet is listed under "Known limitations"
> in the [README](../../README.md).

MockREST is the REST extension of the MockCore platform (`MockRESTCore` = portable engine,
`MockREST` = the `MockService` + facade). It mocks a stateful REST backend for UI tests, defined
by an **OpenAPI spec**, a **Swift DSL**, or both together.

## 1. Two ways to define an API (composable)

```swift
// (a) From an OpenAPI spec — every path becomes mockable; schemas drive generation & validation.
let server = try await MockRESTServer.start(
    spec: .file(specPath),      // absolute paths — see "Locating spec and seed files" in the README
    seed: .file(seedPath)
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
  "Matches" means the same method and the same path *shape*: parameter names do not have to
  agree, so `Get("/users/{userId}")` replaces the spec's `/users/{id}`.

The configuration block is a result builder that supports `if`/`else`, `switch`, and `for`, and
`MockRESTServer.start` / `MockRESTEngine.init` run on the caller's actor, so the block can be
written inline in a `@MainActor` test method.

## 2. OpenAPI ingestion (hand-rolled decoder + validation)

- **Versions:** OpenAPI **3.0.x and 3.1.x**. Swagger 2.0 is rejected with guidance to convert
  upstream (§9.1). 3.1 aligns with JSON Schema 2020-12; 3.0 has its own subset — both are
  normalized into one internal model (`RESTSpec`, whose schema shapes are `SchemaNode`s).
- **Parsing:** the spec is JSON or YAML, so this is a **decoder + validator**, not a
  character-level parser. The document is decoded into a `MockValue` tree (Yams for YAML,
  Foundation for JSON, both via MockCore) and `SpecLoader` walks that tree, validating as it
  builds the model. This honors the platform's "hand-written for diagnostics + portability, no
  heavy deps" rule without the cost of a real grammar parser.
- **What is consumed:** `paths` → operations (method, `parameters`, `requestBody`,
  `responses`), `components.schemas`, and `example`/`examples`.
- **`$ref`:** internal references only (§9.2). `#/components/schemas/…` is resolved wherever a
  schema may appear; `#/components/parameters/…`, `#/components/requestBodies/…`, and
  `#/components/responses/…` are resolved where a parameter, request body, or response may
  appear. External/remote references fail with a clear "not supported in v1" error.
- **Parameters:** `in: path`, `query`, and `header` are modeled; `in: cookie` is accepted and
  ignored. A request missing a `required: true` query or header parameter gets a `400` naming
  it (header parameters named `Accept`, `Content-Type`, or `Authorization` are ignored, as
  OpenAPI specifies).
- **Objects:** an object that declares `properties` is closed unless it opts in with
  `additionalProperties: true` or a schema — unknown keys in seeds and request bodies are
  rejected with a "did you mean", which is what catches typos. `type: object` with no
  `properties` is free-form.
- **Not supported (fail at load with a clear error):** `allOf`; inline (non-`$ref`) variants in
  `oneOf`/`anyOf`; a `requestBody` with no `application/json` content; `type` arrays with more
  than one non-null type.
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
  MockQL). The id field name defaults to `id` and is configurable per resource with `idField`
  (`userId`, `uuid`) (§9.4).
- **References are schema-driven.** A string in a field whose schema type is another object schema
  is a reference to that record's id (`Cart.owner: User` → `owner: "user-1"`). A string in a
  scalar field is a literal. For `oneOf`/`anyOf` (union-ish) positions, use the qualified
  `Schema:id` form so the concrete type is known — same rule as MockQL interfaces/unions.
- **Embedded objects.** A nested map is an anonymous embedded value object (e.g. an inline
  `Address`), not a reference. In a `oneOf`/`anyOf` position an embedded object is validated
  against each variant in declared order and takes the first it satisfies.
- **Omitted fields are generated and stable.** Any schema field not present in the seed is filled
  by its configured generator, or by a default: an `enum` yields one of its members,
  `format: uuid` a UUID, `format: date`/`date-time` a timestamp, and integers, numbers, and
  booleans a value of their type. Other strings are inferred from the **field name** (`email` →
  an email address, `phone` → a phone number, `name` → a full name, …) — `format: email` and
  `pattern` are not consulted. A field typed by a `$ref` to a scalar, enum, or array schema
  generates like the schema it names; omitted arrays are `[]` and omitted references to object
  schemas are `null`. Values are stable for the server's lifetime. `field: null` pins an
  explicit null (nullable fields only).
- **Generators** are keyed `"Schema.field"` when spec-driven (`"User.email": .email`) and
  `"resource.field"` in DSL-only mode, where the bound fields are also what tells the engine
  which omitted fields to fill. Keys are validated at startup either way.

### Seed format (v1)

Mirrors MockQL's `version` / `data` with REST-appropriate wiring (`resources` in place of
MockQL's `roots`):

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

resources:                  # wires collections to their base paths
  users:    { schema: User,    path: /users }     # optional: idField: userId
  products: { schema: Product, path: /products }
  carts:    { schema: Cart,    path: /carts }
```

- The `resources:` block (§9.3) is what makes a collection addressable and enables auto-CRUD
  (§5). When a spec is present, MockREST infers collections from paths + response schemas — a
  `/things` + `/things/{param}` pair whose responses resolve to a named object schema with an
  `id` property — so `resources:` is optional and acts as an override.
- A schema-level `example` in the spec seeds one record of that schema **only when no `data:` is
  provided for it** (§9.5): examples give a zero-config starting world but never fight an
  author's fixtures.

## 4. Request matching

The host hands MockREST a `MockRequest` (method, path, query, headers, raw body). MockREST
decodes the body into a `MockValue`, wraps the request as a `RESTRequest`, and matches it
against its route table:

- **Path templates** `/users/{id}` extract path params. `req.pathParam("id")` reads them
  (percent-decoded). A parameter may share a segment with literal text
  (`/files/{name}.json`, `/users/{id}:activate`); two parameters in one segment need literal
  text between them.
- **Precedence:** literal segments beat partly-literal ones, which beat whole-segment
  parameters (`/users/me` before `/users/{id}`); longer patterns win ties. Deterministic and
  documented.
- **Query params** (`?limit=20&sort=name`) are parsed into `req.query`.
- **`HEAD`** is answered by the matching `GET` route — same status and headers, no body —
  unless an endpoint is declared for `HEAD` itself.
- **Content negotiation:** JSON only in v1 (§9.10). A request whose `Accept` header excludes
  `application/json` gets `406`. A request body that is not valid JSON gets `400`, unless it
  neither claims nor attempts to be JSON (a form post, plain text), in which case it reaches the
  handler as a `.string` — useful to hand-written endpoints; spec-driven routes answer `422`.
- **`claims(_:)`** returns true when the **path** matches a known route, under any method — so
  a wrong method gets MockREST's diagnostic `405` (with `Allow`) rather than falling through.
  Unmatched paths fall through so another service (or the host's 404) handles them — important
  for REST+GraphQL coexistence where GraphQL owns `/graphql`.

## 5. CRUD auto-wiring (hybrid: auto + override)

For each resource collection (from spec or `resources:`), MockREST auto-implements conventional
CRUD against the shared store, all overridable by a DSL endpoint of the same method+path:

| Method & path            | Behavior                                                        | Success |
|--------------------------|----------------------------------------------------------------|---------|
| `GET /users`             | list; pagination + filter + sort (below)                       | 200     |
| `GET /users/{id}`        | fetch one; missing → 404                                        | 200/404 |
| `POST /users`            | create; generate id if absent; validate against schema         | 201 + `Location` |
| `PUT /users/{id}`        | replace; missing → 404 (never an upsert, §9.8)                  | 200/404 |
| `PATCH /users/{id}`      | merge fields                                                    | 200     |
| `DELETE /users/{id}`     | remove; idempotent                                             | 204     |

- **Pagination (§9.6).** `limit`/`offset`. When the spec's list response schema is an envelope
  (an object with exactly one array-of-items property, e.g. `{items, total, offset}`), that
  shape is synthesized instead of a bare array: `total`/`count`, `limit`/`pageSize`/`per_page`,
  `offset`, and `page` are filled from the query; other properties are generated. Cursor
  pagination is deferred.
- **Filtering/sorting (§9.7).** `?field=value` filters by equality, `?sort=field` /
  `?sort=-field` sorts. A query parameter is a filter only when it names a field of the
  collection (a schema property, or a field some stored record has); any other parameter —
  `?page=2`, `?include=owner`, a cache-buster — is ignored. Filters match **stored** values;
  fields filled by generators at read time are not filterable. Kept minimal and documented;
  complex query semantics are a non-goal (this is a test mock, not a query engine).
- **Validation (§9.8).** POST/PUT/PATCH bodies validate against the schema; violations → `422`
  with field-path diagnostics (`body.address.city`). POST and PUT enforce `required` at every
  depth (the id field of a create excepted — the server generates it); PATCH does not. `400` is
  reserved for malformed syntax, bad `limit`/`offset`, and missing required parameters.
- **Ids.** A create with an id that already exists is a `409`. `Location` percent-encodes the
  id.
- **Auto-CRUD is opt-in-per-resource, not global** — a resource only gets CRUD if it's declared as
  a collection (or the spec defines those operations). Non-collection schemas (e.g. `Money`) never
  get endpoints.

## 6. Endpoint DSL & responses

```swift
Get("/users/{id}") { req, state in
    let user = state["User", id: req.pathParam("id")]      // `.null` when there is no such record
    guard !user.isNull else { return .notFound }
    return .ok(user)
}

Post("/orders") { req, state in
    let order = state.insert("Order", req.body)             // generates an id when the body has none
    return .created(order, location: "/orders/\(order["id"].stringValue ?? "")")
}
```

- **`req`** (`RESTRequest`): `method`, `path`, `pathParam(_:)`, `query`/`queryValue(_:)`,
  `headers`/`header(_:)`, `body` (a `MockValue`).
- **`state`** (`MutationState`): the shared MockCore store handle — the same subscript /
  `update` / `insert` / `delete` / `records(ofType:)` surface MockQL mutation closures use, so
  mutation code is portable across protocols. Writes commit atomically when the handler
  returns; a thrown error discards them and becomes a `500`.
- **`RESTResponse` builders**: `.ok(_)`, `.created(_, location:)`, `.noContent`, `.notFound`,
  `.notFound(_:)`, `.status(_, body:)`, `.errors(status:_:)`, plus the plain initializer for
  header control. Bodies are `MockValue`; `.reference` values inside a body are replaced by the
  records they point at, within the handler's own transaction. A hand-written handler's body is
  otherwise sent as returned — schema-driven generation of omitted fields applies to the
  auto-wired routes.
- **Response synthesis from spec.** For auto-wired endpoints, MockREST picks the lowest
  declared 2xx response (else `default`), builds the body from the response schema + stored
  record + generators, and serves a declared `example` in preference to synthesis.

## 7. Validation & diagnostics (fail-fast, before bind)

`MockRESTEngine.init` validates the whole configuration and throws on any error, so nothing is
ever bound for a misconfigured engine: unknown `$ref`; seed record for an unknown schema (with
suggestions); seed field not in schema; dangling reference; duplicate id; enum/scalar mismatch;
a generator key naming an unknown schema, field, or resource; a malformed route template;
circular `$ref` alias chains. (Cross-service path precedence — e.g. coexisting with GraphQL's
`/graphql` — is governed by `MockHost` registration order.) Every diagnostic carries the source
name + JSON/YAML path and, where applicable, a "did you mean".

Not validated: the parameter names a handler closure asks for. `req.pathParam("typo")` returns
`""`.

## 8. Cross-cutting features

What v1 ships (§9.9) and what it leaves for later:

- **Auth simulation** — `.bearer(validTokens:)`: every request except a CORS preflight must
  carry `Authorization: Bearer <token>` with a listed token, else `401`. The spec's `security`
  schemes are not read; OAuth flows are out of scope.
- **Latency & fault injection** — `.delay(_)` delays every request (a request cancelled during
  the delay never runs its handler); `failNext(status:count:)` forces the next matched
  request(s) to fail, for testing loading and error UI.
- **CORS / preflight** — on by default with permissive localhost behavior (the request's
  origin is echoed, with `Vary: Origin` and `Access-Control-Expose-Headers`);
  `MockRESTOptions(cors: false)` turns it off.
- **Non-JSON content types** — later milestone (see §4).
- **Recorded-response seeding** — normalize a captured JSON payload into records; a stretch goal,
  parallels MockQL's TODO.

## 9. Decisions (settled)

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
