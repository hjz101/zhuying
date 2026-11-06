import Foundation

/// Old names are read only for upgrades; all new writes use the current brand.
enum BrandCompatibility {
    static func legacy(_ value: String) -> String? {
        let old = value.replacingOccurrences(of: "zhuying", with: "yueshan")
            .replacingOccurrences(of: "Zhuying", with: "Yueshan")
        return old == value ? nil : old
    }
    static func accepts(_ value: String?, current: String) -> Bool {
        value == current || (value != nil && value == legacy(current))
    }
    static func migrateKeys(_ defaults: UserDefaults) {
        for (key, value) in defaults.dictionaryRepresentation() where key.hasPrefix("yueshan.") {
            let renamed = "zhuying." + key.dropFirst("yueshan.".count)
            if defaults.object(forKey: renamed) == nil { defaults.set(value, forKey: renamed) }
            defaults.removeObject(forKey: key)
        }
    }
    static func defaults(domain: String, migrateLegacy: Bool = true) -> UserDefaults {
        let result = UserDefaults(suiteName: domain)!
        let marker = "zhuying.brand-migration.v1"
        if migrateLegacy, !result.bool(forKey: marker), let oldDomain = legacy(domain) {
            for (key, value) in result.persistentDomain(forName: oldDomain) ?? [:] {
                let renamed = key.replacingOccurrences(of: "yueshan.", with: "zhuying.")
                if result.object(forKey: renamed) == nil { result.set(value, forKey: renamed) }
            }
            result.set(true, forKey: marker)
        }
        if migrateLegacy { migrateKeys(result) }
        return result
    }
}
