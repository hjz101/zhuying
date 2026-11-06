import Foundation

enum LegadoNetworkOrigins {
    static func all(source: DemoSource, state: LegadoPersistentState) throws -> [URL] {
        let definition = try LegadoSourceDefinition.decode(source)
        return try LegadoSourcePolicy(sourceID: source.id, declaredOrigins: definition.policy.allowedOrigins, additionalOrigins: state.allowedOrigins()).allowedOrigins
    }
    @discardableResult static func allow(_ address: String, source: DemoSource, state: LegadoPersistentState) throws -> URL {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw LegadoCompatibilityError.invalid("HTTPS 主机") }
        let origin = try LegadoSourcePolicy.canonicalOrigin(url)
        _ = try LegadoSourcePolicy(sourceID: source.id, declaredOrigins: LegadoSourceDefinition.decode(source).policy.allowedOrigins,
                                   additionalOrigins: state.allowedOrigins() + [origin])
        try state.setAllowedOrigins(state.allowedOrigins() + [origin])
        return origin
    }
}
