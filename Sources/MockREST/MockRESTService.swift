import Foundation
import MockCoreTransport
import MockRESTCore

/// MockREST's conformance to the MockCore platform's extension seam.
///
/// The engine claims exactly the paths its route table knows (spec paths, resource CRUD, DSL
/// endpoints) and leaves everything else to sibling services — which is what lets REST and
/// GraphQL mocks share one port.
extension MockRESTEngine: MockService {
    /// The service name shown in host diagnostics.
    public var name: String {
        "MockREST"
    }

    /// Whether this engine has a route for the request's path, under any method — so a wrong
    /// method gets MockREST's diagnostic `405` instead of falling through to the host's `404`.
    public func claims(_ request: MockRequest) -> Bool {
        matches(path: request.path)
    }

    /// Decodes the HTTP request, executes it against the engine, and encodes the response as
    /// JSON.
    public func respond(to request: MockRequest) async -> MockResponse {
        let body: MockValue
        if request.body.isEmpty {
            body = .null
        } else {
            do {
                body = try MockValue.fromJSONData(request.body)
            } catch {
                // A body that is not JSON is handed to the handler as text — a hand-written
                // endpoint may well accept a form post or a plain-text upload. A client that
                // *says* what it is sending (`text/plain`, `text/csv`, …) is believed, braces
                // and all. Only a body with no declared type, or the form-urlencoded label that
                // URLSession and curl apply to a JSON body unless told otherwise, is judged by
                // its first byte: if it opens like JSON it is held to being JSON.
                let contentType = request.header("Content-Type")
                let claimsJSON = contentType.map(Self.isJSON) ?? false
                let typeIsInformative = contentType.map { !Self.isFormURLEncoded($0) } ?? false
                guard !claimsJSON, typeIsInformative || !Self.opensLikeJSON(request.body) else {
                    return Self.failure(status: 400, message: "Request body is not valid JSON")
                }
                body = .string(String(decoding: request.body, as: UTF8.self))
            }
        }
        let restRequest = RESTRequest(
            method: request.method,
            path: request.path,
            query: request.queryItems,
            headers: request.headers,
            body: body
        )
        // The transport drops a HEAD response's body itself, after measuring it.
        let response = await execute(restRequest, keepingHeadBody: true)
        var mockResponse = MockResponse(status: response.status)
        if let responseBody = response.body {
            do {
                mockResponse.body = try responseBody.jsonData()
            } catch {
                // E.g. a handler returned NaN. An empty 200 would send the test author looking
                // for the bug in their app; say what actually went wrong.
                var failed = Self.failure(
                    status: 500,
                    message: "Response body could not be encoded as JSON: \(error.localizedDescription)"
                )
                failed.headers.append(
                    contentsOf: response.headers.filter {
                        $0.name.lowercased().hasPrefix("access-control-") || $0.name.lowercased() == "vary"
                    })
                return failed
            }
            // A handler that set its own Content-Type (a vendor `+json` type, say) keeps it.
            if !response.headers.contains(where: { $0.name.lowercased() == "content-type" }) {
                mockResponse.headers.append(("Content-Type", "application/json"))
            }
        }
        mockResponse.headers.append(contentsOf: response.headers)
        return mockResponse
    }

    private static func isJSON(_ contentType: String) -> Bool {
        let mediaType =
            contentType.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            ?? ""
        return mediaType == "application/json" || mediaType.hasSuffix("+json")
    }

    /// The label URLSession and curl put on a body whose type the caller never set — so it says
    /// nothing about what the body actually is.
    private static func isFormURLEncoded(_ contentType: String) -> Bool {
        let mediaType =
            contentType.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            ?? ""
        return mediaType == "application/x-www-form-urlencoded"
    }

    /// Whether the first non-whitespace byte starts a JSON object or array.
    private static func opensLikeJSON(_ body: Data) -> Bool {
        let whitespace: Set<UInt8> = [0x20, 0x09, 0x0A, 0x0D]
        guard let first = body.first(where: { !whitespace.contains($0) }) else { return false }
        return first == UInt8(ascii: "{") || first == UInt8(ascii: "[")
    }

    private static func failure(status: Int, message: String) -> MockResponse {
        let payload: MockValue = ["errors": [["message": .string(message)]]]
        return (try? .json(payload, status: status)) ?? MockResponse(status: status)
    }
}
