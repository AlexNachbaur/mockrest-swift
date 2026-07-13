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
API-consuming code, or on platforms where SwiftNIO is unavailable (such as Windows):

```swift
import MockRESTCore

let engine = try await MockRESTEngine(
    spec: .file("Schemas/api.yaml"),
    seed: .file("Fixtures/world.yaml")
)
let response = await engine.execute(RESTRequest(method: "GET", path: "/users/user-1"))
```

Everything is validated in the initializer — unknown `$ref`s, seed typos, dangling references,
malformed endpoint templates — so a misconfigured engine never serves a request. Diagnostics
carry document paths (`paths./users/{id}.get.responses.200`, `data.User[0].email`) and
"did you mean" suggestions.

### Defining an API

An engine can be driven by a spec, by declarations, or both — a declared endpoint whose method
and path match a spec operation replaces the auto-wired handler:

```swift
let engine = try await MockRESTEngine(spec: .file("api.yaml")) {
    Resource("tasks", idField: "taskId")            // auto-CRUD without a spec
    Post("/users/{userId}/verify") { req, state in  // custom behavior over shared state
        state.update("User", id: req.pathParam("userId")) { $0["verified"] = true }
        return .ok(state["User", id: req.pathParam("userId")])
    }
}
```

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

