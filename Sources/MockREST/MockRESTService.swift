import Foundation
import MockCoreTransport
import MockRESTCore

/// MockREST's conformance to the MockCore platform's extension seam.
///
/// The engine claims exactly the paths its route table knows (spec paths, resource CRUD, DSL
/// endpoints) and leaves everything else to sibling services — which is what lets REST and
/// GraphQL mocks share one port.
extension MockRESTEngine: MockService {
    public var name: String {
        "MockREST"
    }

    public func claims(_ request: MockRequest) -> Bool {
        matches(path: request.path)
    }

    public func respond(to request: MockRequest) async -> MockResponse {
        let body: MockValue
        if request.body.isEmpty {
            body = .null
        } else {
            do {
                body = try MockValue.fromJSONData(request.body)
            } catch {
                let payload: MockValue = ["errors": [["message": "Request body is not valid JSON"]]]
                return (try? .json(payload, status: 400)) ?? MockResponse(status: 400)
            }
        }
        let restRequest = RESTRequest(
            method: request.method,
            path: request.path,
            query: request.queryItems,
            headers: request.headers,
            body: body
        )
        let response = await execute(restRequest)
        var mockResponse = MockResponse(status: response.status)
        if let responseBody = response.body {
            mockResponse.body = (try? responseBody.jsonData()) ?? Data()
            mockResponse.headers.append(("Content-Type", "application/json"))
        }
        mockResponse.headers.append(contentsOf: response.headers)
        return mockResponse
    }
}
