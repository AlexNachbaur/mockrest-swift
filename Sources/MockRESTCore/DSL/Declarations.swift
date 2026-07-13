import MockCore

/// An endpoint handler: the request plus a transactional view of the shared state store.
///
/// The `MutationState` surface is the same one MockQL mutation closures receive, so state
/// manipulation code is portable across protocol mocks. Writes commit atomically when the
/// handler returns; a thrown error discards them.
public typealias RESTHandler = @Sendable (RESTRequest, inout MutationState) throws -> RESTResponse

/// A configuration-block declaration: endpoints, resources, and future extension points.
public protocol MockRESTDeclaration: Sendable {}

/// A hand-written endpoint. Its method + path override any auto-wired handler for the same
/// route (spec-driven or CRUD).
public struct Endpoint: MockRESTDeclaration {
    /// The HTTP method, uppercased.
    public let method: String
    /// The path template (`/users/{id}`), validated at engine startup.
    public let path: String
    /// The handler run for matched requests.
    public let handler: RESTHandler

    /// Creates an endpoint for an arbitrary method.
    public init(method: String, _ path: String, handler: @escaping RESTHandler) {
        self.method = method.uppercased()
        self.path = path
        self.handler = handler
    }
}

/// A `GET` endpoint.
public struct Get: MockRESTDeclaration {
    let endpoint: Endpoint

    /// Creates a `GET` endpoint.
    public init(_ path: String, _ handler: @escaping RESTHandler) {
        endpoint = Endpoint(method: "GET", path, handler: handler)
    }
}

/// A `POST` endpoint.
public struct Post: MockRESTDeclaration {
    let endpoint: Endpoint

    /// Creates a `POST` endpoint.
    public init(_ path: String, _ handler: @escaping RESTHandler) {
        endpoint = Endpoint(method: "POST", path, handler: handler)
    }
}

/// A `PUT` endpoint.
public struct Put: MockRESTDeclaration {
    let endpoint: Endpoint

    /// Creates a `PUT` endpoint.
    public init(_ path: String, _ handler: @escaping RESTHandler) {
        endpoint = Endpoint(method: "PUT", path, handler: handler)
    }
}

/// A `PATCH` endpoint.
public struct Patch: MockRESTDeclaration {
    let endpoint: Endpoint

    /// Creates a `PATCH` endpoint.
    public init(_ path: String, _ handler: @escaping RESTHandler) {
        endpoint = Endpoint(method: "PATCH", path, handler: handler)
    }
}

/// A `DELETE` endpoint.
public struct Delete: MockRESTDeclaration {
    let endpoint: Endpoint

    /// Creates a `DELETE` endpoint.
    public init(_ path: String, _ handler: @escaping RESTHandler) {
        endpoint = Endpoint(method: "DELETE", path, handler: handler)
    }
}

/// Declares a resource collection, enabling auto-CRUD for it.
///
/// With an OpenAPI spec, resources are usually inferred from the paths; declare one explicitly
/// to override the inference or to model state in DSL-only mode (no spec).
public struct Resource: MockRESTDeclaration {
    /// The collection name (used in diagnostics; conventionally the plural path segment).
    public let name: String
    /// The schema (with a spec) or type namespace (DSL-only) records belong to.
    public let schema: String
    /// The collection's base path (`/users`).
    public let path: String
    /// The record field holding the id. Defaults to `"id"`.
    public let idField: String

    /// Declares a resource.
    ///
    /// - Parameters:
    ///   - name: The collection name, e.g. `"users"`.
    ///   - schema: The schema/type records belong to; defaults to the capitalized singular of
    ///     `name` is **not** guessed — it defaults to `name` itself. Pass it explicitly when a
    ///     spec is present.
    ///   - path: The base path; defaults to `"/" + name`.
    ///   - idField: The id field name; defaults to `"id"`.
    public init(_ name: String, schema: String? = nil, path: String? = nil, idField: String = "id") {
        self.name = name
        self.schema = schema ?? name
        self.path = path ?? "/\(name)"
        self.idField = idField
    }
}

/// Collects `MockRESTServer`/`MockRESTEngine` configuration declarations.
@resultBuilder
public struct MockRESTBuilder {
    public static func buildBlock(_ declarations: any MockRESTDeclaration...) -> [any MockRESTDeclaration] {
        declarations
    }

    public static func buildOptional(_ declarations: [any MockRESTDeclaration]?) -> [any MockRESTDeclaration] {
        declarations ?? []
    }

    public static func buildEither(first declarations: [any MockRESTDeclaration]) -> [any MockRESTDeclaration] {
        declarations
    }

    public static func buildEither(second declarations: [any MockRESTDeclaration]) -> [any MockRESTDeclaration] {
        declarations
    }
}

extension MockRESTDeclaration {
    /// The endpoint carried by this declaration, when it is one.
    var asEndpoint: Endpoint? {
        switch self {
        case let endpoint as Endpoint: return endpoint
        case let get as Get: return get.endpoint
        case let post as Post: return post.endpoint
        case let put as Put: return put.endpoint
        case let patch as Patch: return patch.endpoint
        case let delete as Delete: return delete.endpoint
        default: return nil
        }
    }
}
