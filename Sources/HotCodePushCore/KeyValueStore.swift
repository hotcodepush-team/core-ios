import Foundation

/// The platform's key-value store, one value per key in the store's native type; `UserDefaults` on iOS, an in-memory map in tests.
public protocol KeyValueStore: AnyObject {
    func string(forKey key: String) -> String?
    func set(_ value: String?, forKey key: String)
    func integer(forKey key: String) -> Int?
    func set(_ value: Int?, forKey key: String)
}

public final class UserDefaultsStore: KeyValueStore {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func string(forKey key: String) -> String? {
        return defaults.string(forKey: key)
    }

    public func set(_ value: String?, forKey key: String) {
        if let value = value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    public func integer(forKey key: String) -> Int? {
        return defaults.object(forKey: key) as? Int
    }

    public func set(_ value: Int?, forKey key: String) {
        if let value = value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
