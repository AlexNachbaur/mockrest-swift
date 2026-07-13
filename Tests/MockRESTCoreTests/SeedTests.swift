import Testing

@testable import MockRESTCore

@Suite struct RESTSeedTests {
    private func engine(seed: String) async throws -> MockRESTEngine {
        try await MockRESTEngine(spec: .yaml(Fixtures.shopSpec), seed: .yaml(seed), serverSeed: 7)
    }

    @Test func referencesResolveByFieldSchema() async throws {
        let engine = try await Fixtures.shopEngine()
        let cart = await engine.store.record(type: "Cart", id: "c1")
        #expect(cart?["owner"] == .reference("User", id: "u1"))
        #expect(cart?["items"] == .list([.reference("Product", id: "p1"), .reference("Product", id: "p2")]))
    }

    @Test func unknownSchemaGetsSuggestion() async {
        await expectSeedError(
            """
            version: 1
            data:
              Usr:
                - {id: u1}
            """,
            contains: "Did you mean 'User'?"
        )
    }

    @Test func unknownFieldGetsSuggestion() async {
        await expectSeedError(
            """
            version: 1
            data:
              User:
                - {id: u1, nmae: Avery}
            """,
            contains: "Did you mean 'name'?"
        )
    }

    @Test func duplicateIdsAreRejected() async {
        await expectSeedError(
            """
            version: 1
            data:
              User:
                - {id: u1, name: A, email: a@example.com}
                - {id: u1, name: B, email: b@example.com}
            """,
            contains: "Duplicate id 'u1'"
        )
    }

    @Test func danglingReferencesAreRejected() async {
        await expectSeedError(
            """
            version: 1
            data:
              Cart:
                - {id: c1, owner: u9}
            """,
            contains: "Dangling reference"
        )
    }

    @Test func enumMembersAreValidated() async {
        await expectSeedError(
            """
            version: 1
            data:
              User:
                - {id: u1, name: A, email: a@example.com, status: activ}
            """,
            contains: "Did you mean 'active'?"
        )
    }

    @Test func unknownTopLevelKeyGetsSuggestion() async {
        await expectSeedError("version: 1\ndatas: {}", contains: "Did you mean 'data'?")
    }

    @Test func missingVersionIsAnError() async {
        await expectSeedError("data: {}", contains: "version: 1")
    }

    @Test func intIdsCoerceToStrings() async throws {
        let engine = try await engine(
            seed: """
                version: 1
                data:
                  User:
                    - {id: 7, name: Avery, email: a@example.com}
                """
        )
        let user = await engine.store.record(type: "User", id: "7")
        #expect(user?["id"] == .string("7"))
    }

    @Test func schemaExamplesSeedOnlyWhenNoData() async throws {
        // With explicit User data the example must NOT load.
        let seeded = try await Fixtures.shopEngine()
        let all = await seeded.store.records(ofType: "User")
        #expect(all.count == 2)

        // Without a seed, the User schema example becomes the starting world.
        let bare = try await MockRESTEngine(spec: .yaml(Fixtures.shopSpec), serverSeed: 7)
        let example = await bare.store.record(type: "User", id: "seed-user")
        #expect(example?["name"] == .string("Example User"))
    }

    @Test func dslModeSeedsResourceCollections() async throws {
        let engine = try await MockRESTEngine(
            seed: .yaml(
                """
                version: 1
                data:
                  tasks:
                    - {taskId: t1, title: Write tests}
                resources:
                  tasks: {path: /tasks, idField: taskId}
                """
            ),
            serverSeed: 7
        )
        let task = await engine.store.record(type: "tasks", id: "t1")
        #expect(task?["title"] == .string("Write tests"))
    }

    private func expectSeedError(_ seed: String, contains fragment: String) async {
        do {
            _ = try await engine(seed: seed)
            Issue.record("Expected a seed error containing '\(fragment)'")
        } catch let error as MockError {
            #expect(error.category == .seed, "unexpected category for: \(error)")
            #expect(error.message.contains(fragment), "expected '\(fragment)' in: \(error.message)")
        } catch {
            Issue.record("Expected a MockError, got \(error)")
        }
    }
}
