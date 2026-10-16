import Darwin
import Foundation

/// Guarded private Apple API. Each call checks the selector or symbol exists, then falls back (nil, false,
/// or no-op) if not, so a macOS that drops one degrades instead of throwing. The app passes real objects;
/// tests pass stand-ins that lack the selector, so the fallback actually runs.
public enum PrivateAPI {
    /// The value of KVC `key` on `object`, or nil when `object` has no selector named `key`.
    public static func value(of object: NSObject, forKey key: String) -> Any? {
        guard object.responds(to: NSSelectorFromString(key)) else { return nil }
        return object.value(forKey: key)
    }

    /// `value(of:forKey:)` as a 32-bit integer (a pid), or nil when missing or not a number.
    public static func int32(of object: NSObject, forKey key: String) -> Int32? {
        (value(of: object, forKey: key) as? NSNumber)?.int32Value
    }

    /// `value(of:forKey:)` as an unsigned 64-bit integer (a byte count), or nil when missing or not a number.
    public static func uint64(of object: NSObject, forKey key: String) -> UInt64? {
        (value(of: object, forKey: key) as? NSNumber)?.uint64Value
    }

    /// `value(of:forKey:)` as a Bool, false when missing or not a number.
    public static func bool(of object: NSObject, forKey key: String) -> Bool {
        (value(of: object, forKey: key) as? NSNumber)?.boolValue ?? false
    }

    /// The pid `_webProcessIdentifier` reports for a web view. Nil when WebKit lacks the property, or the view has no
    /// process yet (WebKit reports 0).
    public static func webProcessIdentifier(of webView: NSObject) -> pid_t? {
        guard let pid = int32(of: webView, forKey: "_webProcessIdentifier"), pid > 0 else { return nil }
        return pid
    }

    /// The object returned by the argument-less selector `name` on `receiver` (an object or a class), or nil when
    /// `receiver` has no such method.
    public static func call(_ name: String, on receiver: AnyObject) -> AnyObject? {
        let selector = NSSelectorFromString(name)
        guard receiver.responds(to: selector) else { return nil }
        return receiver.perform(selector)?.takeUnretainedValue()
    }

    /// Calls the argument-less, void-returning selector `name` on `receiver`, or does nothing when
    /// `receiver` has no such method.
    public static func callVoid(_ name: String, on receiver: AnyObject) {
        let selector = NSSelectorFromString(name)
        guard receiver.responds(to: selector) else { return }
        typealias VoidMethod = @convention(c) (AnyObject, Selector) -> Void
        let method = receiver.method(for: selector)
        let imp = unsafeBitCast(method, to: VoidMethod.self)
        imp(receiver, selector)
    }

    /// The C function `name` from any loaded image (`RTLD_DEFAULT`), typed as `Function` (a `@convention(c)` type),
    /// or nil when no loaded image has it.
    public static func function<Function>(named name: String, as _: Function.Type) -> Function? {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }
        return unsafeBitCast(symbol, to: Function.self)
    }

    /// Triggers a JavaScript engine garbage collection pass and process cache purge across WebKit processes.
    public static func trimWebKitMemory(on object: NSObject) {
        let pool: NSObject?
        if let config = value(of: object, forKey: "configuration") as? NSObject,
           let p = value(of: config, forKey: "processPool") as? NSObject {
            pool = p
        } else if let p = value(of: object, forKey: "processPool") as? NSObject {
            pool = p
        } else {
            pool = object
        }
        if let pool {
            callVoid("_garbageCollectJavaScriptObjectsForTesting", on: pool)
            callVoid("_clearWebProcessCache", on: pool)
        }
    }
}

/// Switches on WebKit features that WebKit ships off, through the private `+_features` list of `WKPreferences` and
/// `-_setEnabled:forFeature:`.
public enum WebFeatureToggles {
    public enum Outcome: Equatable, Sendable {
        /// The features were switched on; the strings are their `key`s.
        case applied([String])
        /// Nothing changed; the reason says which part is missing.
        case unavailable(String)
    }

    /// The feature objects in `source`'s `_features` list whose `key` is in `wanted`. Empty when the list is missing.
    /// The list holds hundreds of objects, so callers keep the result instead of asking for it per web view.
    public static func features(named wanted: Set<String>, in source: AnyObject) -> [NSObject] {
        guard let all = PrivateAPI.call("_features", on: source) as? [NSObject] else { return [] }
        return all.filter { feature in
            guard let key = PrivateAPI.value(of: feature, forKey: "key") as? String else { return false }
            return wanted.contains(key)
        }
    }

    /// Switches each feature on in `preferences`. Changes nothing, and says so, when there are no features or WebKit
    /// lacks `_setEnabled:forFeature:`.
    @discardableResult
    public static func enable(_ features: [NSObject], in preferences: NSObject) -> Outcome {
        guard !features.isEmpty else { return .unavailable("WebKit lists no features") }
        let setSelector = NSSelectorFromString("_setEnabled:forFeature:")
        guard preferences.responds(to: setSelector) else { return .unavailable("preferences lack _setEnabled:forFeature:") }
        typealias SetFeature = @convention(c) (AnyObject, Selector, Bool, AnyObject) -> Void
        let setFeature = unsafeBitCast(preferences.method(for: setSelector), to: SetFeature.self)
        for feature in features {
            setFeature(preferences, setSelector, true, feature)
        }
        return .applied(features.compactMap { PrivateAPI.value(of: $0, forKey: "key") as? String })
    }
}
