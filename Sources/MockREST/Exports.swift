// MockREST re-exports the portable engine — and the platform transport, so composing MockREST
// with sibling services on one MockHost works with `import MockREST` as the only import.
@_exported import MockCoreTransport
@_exported import MockRESTCore
