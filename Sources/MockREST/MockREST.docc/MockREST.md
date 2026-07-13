# ``MockREST``

A stateful REST mocking server for UI-test automation: the MockRESTCore engine served over
real localhost HTTP.

## Overview

Most tests need exactly one call:

```swift
import MockREST

let server = try await MockRESTServer.start(
    spec: .file("Schemas/api.yaml"),
    seed: .file("Fixtures/world.yaml")
)
app.launchEnvironment["API_BASE_URL"] = server.url.absoluteString
```

``MockRESTServer`` binds an ephemeral loopback port (safe for parallel test runs), validates
everything before accepting connections, and serves the engine's routes as JSON. Use
``MockRESTServer/failNext(status:count:)`` to force failures for error-UI tests, and the
engine's options for latency, bearer-auth simulation, and CORS behavior.

This module re-exports `MockRESTCore` (the portable engine) and `MockCoreTransport` (the
platform's host and service seam), so `import MockREST` is the only import you need — including
when composing REST with sibling protocol mocks:

```swift
import MockQL
import MockREST

let store = StateStore()
let host = try await MockHost.start {
    try await MockRESTEngine(spec: .file("api.yaml"), store: store)
    try await MockQLEngine(schema: .file("shop.graphqls"), store: store)
}
// One URL answers both protocols; a REST POST is visible to a GraphQL query.
```

`MockRESTEngine`'s `MockService` conformance lives in this module: the engine claims exactly
the paths its route table knows and leaves everything else to sibling services or the host's
diagnostic 404.

## Topics

### Server

- ``MockRESTServer``
