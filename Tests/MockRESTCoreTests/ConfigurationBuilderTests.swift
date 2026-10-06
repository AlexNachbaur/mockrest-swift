import MockRESTCore
import Testing

/// The configuration block as callers actually write it: from a `@MainActor` test class, and
/// with ordinary control flow inside the builder.
@Suite struct ConfigurationBuilderTests {
    /// XCUITest `setUp` methods are main-actor-isolated; the configuration closure must be
    /// usable from there without `@Sendable` gymnastics.
    @MainActor
    @Test func engineInitCompilesAndRunsFromTheMainActor() async throws {
        let greeting = "hello"
        let engine = try await MockRESTEngine {
            Resource("tasks")
            Get("/ping") { _, _ in .ok(["greeting": .string(greeting)]) }
        }
        let response = await engine.execute(RESTRequest(method: "GET", path: "/ping"))
        #expect(response.body?["greeting"] == .string("hello"))
    }

    @Test func conditionalsCompileAndSelectDeclarations() async throws {
        func engine(admin: Bool, legacy: Bool) async throws -> MockRESTEngine {
            try await MockRESTEngine {
                Get("/ping") { _, _ in .ok(["pong": true]) }
                if admin {
                    Get("/admin") { _, _ in .ok(["admin": true]) }
                }
                if legacy {
                    Get("/version") { _, _ in .ok(["version": 1]) }
                } else {
                    Get("/version") { _, _ in .ok(["version": 2]) }
                    Resource("tasks")
                }
            }
        }
        let plain = try await engine(admin: false, legacy: true)
        #expect(await plain.execute(RESTRequest(method: "GET", path: "/admin")).status == 404)
        #expect(await plain.execute(RESTRequest(method: "GET", path: "/version")).body?["version"] == .int(1))
        #expect(await plain.execute(RESTRequest(method: "GET", path: "/tasks")).status == 404)

        let full = try await engine(admin: true, legacy: false)
        #expect(await full.execute(RESTRequest(method: "GET", path: "/admin")).status == 200)
        #expect(await full.execute(RESTRequest(method: "GET", path: "/version")).body?["version"] == .int(2))
        #expect(await full.execute(RESTRequest(method: "GET", path: "/tasks")).status == 200)
    }

    @Test func loopsDeclareOneEndpointPerIteration() async throws {
        let engine = try await MockRESTEngine {
            for name in ["alpha", "beta", "gamma"] {
                Get("/flags/\(name)") { _, _ in .ok(["flag": .string(name)]) }
            }
        }
        for name in ["alpha", "beta", "gamma"] {
            let response = await engine.execute(RESTRequest(method: "GET", path: "/flags/\(name)"))
            #expect(response.body?["flag"] == .string(name))
        }
    }

    @Test func anEmptyBlockDeclaresNothing() async throws {
        let engine = try await MockRESTEngine {}
        #expect(await engine.execute(RESTRequest(method: "GET", path: "/anything")).status == 404)
    }
}
