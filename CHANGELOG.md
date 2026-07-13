# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this
project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
