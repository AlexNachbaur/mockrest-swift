# ``MockRESTCore``

The portable MockREST engine: OpenAPI ingestion, seeds, routing, auto-CRUD, and deterministic
response synthesis — no networking dependencies.

## Overview

`MockRESTCore` is everything MockREST does except serve HTTP. A ``MockRESTEngine`` ingests an
OpenAPI 3.0/3.1 document (``SpecSource``), assembles resource collections and hand-written
endpoints, validates seeds against the spec's schemas, and executes ``RESTRequest``s against a
shared, transactional state store. The `MockREST` module puts a real localhost server in front
of it and re-exports this module, so most users just `import MockREST`.

Import `MockRESTCore` directly for in-process execution with no server — for unit tests of
API-consuming code, or on any host that would rather not bind a port:

```swift
import MockRESTCore

let engine = try await MockRESTEngine(
    spec: .file(specPath),
    seed: .file(seedPath)
)
let response = await engine.execute(RESTRequest(method: "GET", path: "/users/user-1"))
```

``SpecSource/file(_:)`` takes a filesystem path, and a relative one is resolved against the
process's working directory — rarely the project folder when tests run. Build an absolute path
from the test bundle: `Bundle.module.path(forResource:ofType:)` in a SwiftPM test target,
`Bundle(for: MyTests.self).path(forResource:ofType:)` in an Xcode test bundle.

Everything is validated in the initializer — unknown `$ref`s, seed typos, dangling references,
malformed endpoint templates — so a misconfigured engine never serves a request. Diagnostics
carry document paths (`paths./users/{id}.get.responses.200`, `data.User[0].email`) and
"did you mean" suggestions.

### Defining an API

An engine can be driven by a spec, by declarations, or both. With a spec, a declared endpoint
whose method and path match a spec operation replaces the auto-wired handler (the path
parameters may be named differently — it is the same route):

```swift
let engine = try await MockRESTEngine(spec: .file(specPath)) {
    Post("/users/{userId}/verify") { req, state in  // custom behavior over shared state
        state.update("User", id: req.pathParam("userId")) { $0["verified"] = true }
        return .ok(state["User", id: req.pathParam("userId")])
    }
}
```

Without a spec, ``Resource`` declarations name the collections and get auto-CRUD, and
generators are keyed by resource:

```swift
let engine = try await MockRESTEngine(generators: ["tasks.assignee": .email]) {
    Resource("tasks", idField: "taskId")            // list/create/get/replace/merge/delete at /tasks
    Get("/ping") { _, _ in .ok(["pong": true]) }
}
```

When a spec *is* present, a ``Resource`` must name one of its object schemas —
`Resource("tasks", schema: "Task")` — and that schema must declare the id field.

The block is a result builder (``MockRESTBuilder``), so `if`/`else`, `switch`, and `for` work
inside it, and the initializer runs on the caller's actor, so it can be written inline from
`@MainActor` code.

## Topics

### Engine

- ``MockRESTEngine``
- ``MockRESTOptions``
- ``SpecSource``

### Requests and responses

- ``RESTRequest``
- ``RESTResponse``

### Endpoint DSL

- ``MockRESTBuilder``
- ``MockRESTDeclaration``
- ``RESTHandler``
- ``Get``
- ``Post``
- ``Put``
- ``Patch``
- ``Delete``
- ``Endpoint``
- ``Resource``

### Routing

- ``RoutePattern``

