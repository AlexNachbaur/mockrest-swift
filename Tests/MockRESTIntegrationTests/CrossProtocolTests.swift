import Foundation
import MockQL
import MockREST
import Testing

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// The platform's headline flow: one `MockHost`, one port, one `StateStore` — answering both
/// REST and GraphQL, with mutations made through either protocol visible through the other.
@Suite struct CrossProtocolTests {
    private static let graphQLSchema = """
        type Query {
            user(id: ID!): User
        }
        type Mutation {
            renameUser(id: ID!, name: String!): User
        }
        type User {
            id: ID!
            name: String!
            email: String!
        }
        """

    private func makeHost() async throws -> (MockHost, StateStore) {
        let store = StateStore()
        let rest = try await MockRESTEngine(
            spec: .yaml(IntegrationFixtures.spec),
            seed: .yaml(IntegrationFixtures.seed),
            serverSeed: 3,
            store: store
        )
        let graphQL = try await MockQLEngine(
            schema: .sdl(Self.graphQLSchema),
            store: store
        ) {
            Mutation("renameUser") { input, state in
                state.update("User", id: input["id"].stringValue ?? "") { user in
                    user["name"] = input["name"]
                }
                return state["User", id: input["id"].stringValue ?? ""]
            }
        }
        let host = try await MockHost.start {
            rest
            graphQL
        }
        return (host, store)
    }

    private func graphQL(_ query: String, host: MockHost) async throws -> MockValue {
        var request = URLRequest(url: try #require(URL(string: "/graphql", relativeTo: host.url)))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try MockValue.object(["query": .string(query)]).jsonData()
        let (data, _) = try await URLSession.shared.data(for: request)
        return try MockValue.fromJSONData(data)
    }

    private func rest(
        _ method: String,
        _ path: String,
        body: MockValue? = nil,
        host: MockHost
    ) async throws -> (Int, MockValue) {
        var request = URLRequest(url: try #require(URL(string: path, relativeTo: host.url)))
        request.httpMethod = method
        if let body {
            request.httpBody = try body.jsonData()
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let value = data.isEmpty ? MockValue.null : ((try? MockValue.fromJSONData(data)) ?? .null)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, value)
    }

    @Test func restMutationIsVisibleToGraphQLQueries() async throws {
        let (host, _) = try await makeHost()

        // Create a user through REST…
        let (created, body) = try await rest(
            "POST", "/users",
            body: ["id": "u3", "name": "Casey Novak", "email": "casey@example.com"],
            host: host
        )
        #expect(created == 201)
        #expect(body["id"] == .string("u3"))

        // …and read it back through GraphQL, same port, same store.
        let response = try await graphQL(#"{ user(id: "u3") { id name email } }"#, host: host)
        #expect(response["data"]["user"]["name"] == .string("Casey Novak"))
        #expect(response["data"]["user"]["email"] == .string("casey@example.com"))
        try await host.stop()
    }

    @Test func graphQLMutationIsVisibleToRESTReads() async throws {
        let (host, _) = try await makeHost()

        let mutation = try await graphQL(
            #"mutation { renameUser(id: "u1", name: "Avery Renamed") { id name } }"#,
            host: host
        )
        #expect(mutation["data"]["renameUser"]["name"] == .string("Avery Renamed"))

        let (status, user) = try await rest("GET", "/users/u1", host: host)
        #expect(status == 200)
        #expect(user["name"] == .string("Avery Renamed"))
        try await host.stop()
    }

    @Test func bothSeedsLoadIntoTheSharedStore() async throws {
        let (host, store) = try await makeHost()

        // REST's seed is in the store the GraphQL engine reads.
        let seeded = try await graphQL(#"{ user(id: "u2") { name } }"#, host: host)
        #expect(seeded["data"]["user"]["name"] == .string("Blake Chen"))
        let count = await store.records(ofType: "User").count
        #expect(count == 2)
        try await host.stop()
    }

    @Test func registrationOrderRoutesEachProtocolToItsService() async throws {
        let (host, _) = try await makeHost()

        // REST answers its paths…
        let (users, _) = try await rest("GET", "/users", host: host)
        #expect(users == 200)
        // …GraphQL answers /graphql…
        let health = try await graphQL("{ __typename }", host: host)
        #expect(health["data"]["__typename"] == .string("Query"))
        // …and unclaimed paths get the host 404 naming both services.
        let (missing, diagnostic) = try await rest("GET", "/nowhere", host: host)
        #expect(missing == 404)
        let message = try #require(diagnostic["error"].stringValue)
        #expect(message.contains("MockREST"))
        #expect(message.contains("MockQL"))
        try await host.stop()
    }
}
