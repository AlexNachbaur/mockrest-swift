# Contributing to MockREST

Thanks for your interest in contributing! MockREST is young and moving quickly, so this guide
is short — when in doubt, open an issue and ask.

## Where things live

MockREST is the REST/OpenAPI extension of the MockCore platform. Protocol-neutral machinery —
the value model, state store, generators, seed primitives, diagnostics, and the
`MockHost`/`MockService` transport — lives in
[mockcore-swift](https://github.com/AlexNachbaur/mockcore-swift); this repository holds
everything REST-specific: spec ingestion, the endpoint DSL, auto-CRUD, seeds, and response
synthesis. If a change would benefit every protocol extension, propose it against MockCore
instead.

## Getting started

1. Install a **Swift 6.1** toolchain — Xcode 16.4+ on macOS, a [swift.org](https://swift.org/install/)
   toolchain on Linux or Windows, or the `swift:6.1` Docker image (which is what CI uses).
2. Fork and clone the repository.
3. Build and test from the command line:

   ```sh
   swift build
   swift test
   ```

   On macOS you can also open `Package.swift` in Xcode 16.4 or later.

Dependencies resolve from GitHub (MockCore, and MockQL for the cross-protocol integration
tests); nothing else is required beyond the toolchain.

## Reporting bugs and requesting features

- Search [existing issues](https://github.com/AlexNachbaur/mockrest-swift/issues) first.
- Use the issue templates — a minimal reproduction (the spec excerpt, seed data, the request,
  and the observed vs. expected response) makes bugs dramatically faster to fix.
- For anything security-sensitive, **do not open a public issue** — see [SECURITY.md](SECURITY.md).

## Code style

Formatting is enforced by `swift-format` using the checked-in [.swift-format](.swift-format)
configuration. CI will fail on lint violations, so run this before pushing:

```sh
swift format lint --strict --recursive Sources Tests Package.swift
```

Beyond formatting, the project follows these rules:

- **120-character line length, 4-space indentation.**
- **No force unwraps** (`!`) in production code.
- **No `DispatchQueue`** — use Swift concurrency (`async`/`await`, actors, structured tasks).
- **Prefer value types** (structs, enums with cases) over reference types.
- **Never use caseless enums as namespaces.** Enums are for enumerated values only. For
  singletons or groupings of static members, use a `struct` with static properties or a
  `final class` with `static let shared`.
- **Error messages are a product feature.** Spec, seed, and request diagnostics carry document
  paths (`paths./users/{id}.get.responses.200`, `data.User[0].email`) and "did you mean"
  suggestions. Never regress an error message.
- **Stay cross-platform.** `MockRESTCore` supports macOS, iOS, Linux, and Android (with
  Windows planned). Don't import Apple-only frameworks in library targets, and stick to
  Foundation APIs available in swift-corelibs-foundation. CI builds and tests on macOS, Linux,
  and an Android emulator, and must pass on all three.

## Pull requests

- Branch from `main`; keep PRs focused on a single change.
- Add or update tests for any behavioral change — unit tests in `Tests/MockRESTCoreTests`,
  full-stack HTTP (and cross-protocol) coverage in `Tests/MockRESTIntegrationTests`.
- Update documentation (README, `docs/design/`, doc comments) when the public API changes.
- Note user-visible changes under the **Unreleased** heading in [CHANGELOG.md](CHANGELOG.md).
- Make sure `swift build`, `swift test`, and the lint command above all pass locally.

While the project is pre-1.0, the public API may change without deprecation cycles, but each
breaking change should be called out in the changelog.

## Design discussions

Larger changes (spec-ingestion scope, the state model, new cross-cutting features) should start
as an issue describing the problem and the proposed approach before any code is written. Design
documents — including the platform architecture and the REST format specification — live in
[docs/design/](docs/design/).

## Code of conduct

All participation in this project is governed by the
[Code of Conduct](CODE_OF_CONDUCT.md).
