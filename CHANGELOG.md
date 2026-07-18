# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this
project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
