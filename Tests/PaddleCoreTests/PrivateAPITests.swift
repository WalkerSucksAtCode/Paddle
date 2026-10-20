import Foundation
import PaddleCore
import Testing
import WebKit

/// Has none of the selectors the guarded calls look for.
private final class BareObject: NSObject {}

/// Has the properties the guarded calls read from WebKit's process and web view objects.
private final class ProcessStandIn: NSObject {
    @objc(_webProcessIdentifier) var webProcessIdentifier: Int32 = 4242
    @objc var pid: Int32 = 99
    @objc var physicalFootprint: UInt64 = 1_048_576
    @objc var runningServiceWorkers = true
}

/// A `_WKFeature` stand-in: only a `key`.
private final class FeatureStandIn: NSObject {
    @objc let key: String

    init(key: String) {
        self.key = key
        super.init()
    }
}

/// Stands in for `WKPreferences` as the class that lists its `_features`.
private final class FeatureListStandIn: NSObject {
    @objc(_features) class func features() -> [NSObject] {
        [FeatureStandIn(key: "RequestIdleCallbackEnabled"), BareObject(), FeatureStandIn(key: "Unrelated")]
    }
}

/// Stands in for `WKPreferences` with `_setEnabled:forFeature:`, recording the features it was asked to switch on.
private final class PreferencesStandIn: NSObject {
    private(set) var enabled: [String] = []

    @objc(_setEnabled:forFeature:) func setEnabled(_ value: Bool, forFeature feature: NSObject) {
        guard value, let key = feature.value(forKey: "key") as? String else { return }
        enabled.append(key)
    }
}

/// `_isEnabledForFeature:` on real preferences. It returns BOOL, so it is read through a typed IMP.
@MainActor
private func isEnabled(_ preferences: WKPreferences, _ feature: NSObject) -> Bool {
    typealias IsEnabled = @convention(c) (AnyObject, Selector, AnyObject) -> Bool
    let selector = NSSelectorFromString("_isEnabledForFeature:")
    return unsafeBitCast(preferences.method(for: selector), to: IsEnabled.self)(preferences, selector, feature)
}

/// Switches a feature off with the same private setter `WebFeatureToggles.enable` uses, for a known starting state.
@MainActor
private func disable(_ preferences: WKPreferences, _ feature: NSObject) {
    typealias SetFeature = @convention(c) (AnyObject, Selector, Bool, AnyObject) -> Void
    let selector = NSSelectorFromString("_setEnabled:forFeature:")
    unsafeBitCast(preferences.method(for: selector), to: SetFeature.self)(preferences, selector, false, feature)
}

/// The guarded private calls: each fallback test runs the path where WebKit lacks the selector (or symbol), and the
/// present-selector tests run against real WebKit objects or stand-ins that have it.
@MainActor
struct PrivateAPITests {
    @Test func missingKeysReadAsFallbacks() {
        let bare = BareObject()
        #expect(PrivateAPI.value(of: bare, forKey: "pid") == nil)
        #expect(PrivateAPI.int32(of: bare, forKey: "pid") == nil)
        #expect(PrivateAPI.uint64(of: bare, forKey: "physicalFootprint") == nil)
        #expect(PrivateAPI.bool(of: bare, forKey: "runningServiceWorkers") == false)
        #expect(PrivateAPI.webProcessIdentifier(of: bare) == nil)
    }

    @Test func missingSelectorCallReturnsNil() {
        #expect(PrivateAPI.call("_webContentProcessInfo", on: BareObject()) == nil)
        #expect(PrivateAPI.call("_features", on: BareObject.self as AnyObject) == nil)
    }

    @Test func featureListWithoutSelectorIsEmpty() {
        #expect(WebFeatureToggles.features(named: ["RequestIdleCallbackEnabled"], in: BareObject()).isEmpty)
    }

    @Test func featureListSkipsFeaturesWithoutKey() {
        let found = WebFeatureToggles.features(
            named: ["RequestIdleCallbackEnabled", "Missing"],
            in: FeatureListStandIn.self as AnyObject
        )
        #expect(found.compactMap { PrivateAPI.value(of: $0, forKey: "key") as? String } == ["RequestIdleCallbackEnabled"])
    }

    @Test func enableWithoutSetterReportsUnavailable() {
        let feature = FeatureStandIn(key: "RequestIdleCallbackEnabled")
        #expect(WebFeatureToggles.enable([feature], in: BareObject())
            == .unavailable("preferences lack _setEnabled:forFeature:"))
        #expect(WebFeatureToggles.enable([], in: PreferencesStandIn()) == .unavailable("WebKit lists no features"))
    }

    @Test func missingSymbolIsNil() {
        typealias GetPID = @convention(c) () -> Int32
        #expect(PrivateAPI.function(named: "paddle_no_such_symbol_for_tests", as: GetPID.self) == nil)
        let getpid = PrivateAPI.function(named: "getpid", as: GetPID.self)
        #expect(getpid?() == ProcessInfo.processInfo.processIdentifier)
    }

    @Test func presentPropertiesReadThroughKVC() {
        let process = ProcessStandIn()
        #expect(PrivateAPI.webProcessIdentifier(of: process) == 4242)
        #expect(PrivateAPI.int32(of: process, forKey: "pid") == 99)
        #expect(PrivateAPI.uint64(of: process, forKey: "physicalFootprint") == 1_048_576)
        #expect(PrivateAPI.bool(of: process, forKey: "runningServiceWorkers"))
    }

    /// KVC on a key the object lacks raises NSUndefinedKeyException, which Swift can't catch: a missing setter must be
    /// skipped, and the keys Paddle sets today must still be set.
    @Test func setValueSkipsMissingKeysAndSetsPresentOnes() {
        #expect(PrivateAPI.setValue(true, forKey: "developerExtrasEnabled", on: BareObject()) == false)
        #expect(PrivateAPI.value(of: BareObject(), forKey: "_configuration") == nil)
        let preferences = WKPreferences()
        #expect(PrivateAPI.setValue(true, forKey: "developerExtrasEnabled", on: preferences))
        #expect((preferences.value(forKey: "developerExtrasEnabled") as? NSNumber)?.boolValue == true)
        let webView = WKWebView()
        #expect(PrivateAPI.setValue(false, forKey: "drawsBackground", on: webView))
        #expect((webView.value(forKey: "drawsBackground") as? NSNumber)?.boolValue == false)
        #expect(PrivateAPI.value(of: WKWebsiteDataStore.nonPersistent(), forKey: "_configuration") != nil)
    }

    @Test func enableCallsSetterForEachFeature() {
        let preferences = PreferencesStandIn()
        let outcome = WebFeatureToggles.enable(
            [FeatureStandIn(key: "RequestIdleCallbackEnabled"), FeatureStandIn(key: "HiddenPageDOMTimerThrottlingAutoIncreases")],
            in: preferences
        )
        #expect(outcome == .applied(["RequestIdleCallbackEnabled", "HiddenPageDOMTimerThrottlingAutoIncreases"]))
        #expect(preferences.enabled == ["RequestIdleCallbackEnabled", "HiddenPageDOMTimerThrottlingAutoIncreases"])
    }

    @Test func realWebViewReportsProcessIdentifierSelector() {
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        // The selector exists and WebKit reports 0 until a page has a process, which reads as no pid.
        #expect(PrivateAPI.int32(of: webView, forKey: "_webProcessIdentifier") == 0)
        #expect(PrivateAPI.webProcessIdentifier(of: webView) == nil)
    }

    @Test func realPreferencesListAndToggleWebFeatures() throws {
        let wanted: Set<String> = ["RequestIdleCallbackEnabled", "HiddenPageDOMTimerThrottlingAutoIncreases"]
        let features = WebFeatureToggles.features(named: wanted, in: WKPreferences.self as AnyObject)
        #expect(Set(features.compactMap { PrivateAPI.value(of: $0, forKey: "key") as? String }) == wanted)

        let preferences = WKPreferences()
        let idle = try #require(features.first {
            PrivateAPI.value(of: $0, forKey: "key") as? String == "RequestIdleCallbackEnabled"
        })
        disable(preferences, idle)
        #expect(!isEnabled(preferences, idle))

        guard case let .applied(keys) = WebFeatureToggles.enable(features, in: preferences) else {
            Issue.record("enable did not apply the features")
            return
        }
        #expect(Set(keys) == wanted)
        #expect(isEnabled(preferences, idle))
    }

    @Test func realLibsystemHasResponsibilityCall() {
        typealias ResponsibleFor = @convention(c) (pid_t) -> pid_t
        #expect(PrivateAPI.function(named: "responsibility_get_pid_responsible_for_pid", as: ResponsibleFor.self) != nil)
    }

    @Test func trimWebKitMemoryDegradesGracefullyOnBareObject() {
        PrivateAPI.trimWebKitMemory(on: BareObject())
    }

    @MainActor
    @Test func trimWebKitMemoryExecutesOnRealWebView() {
        let webView = WKWebView(frame: .zero)
        PrivateAPI.trimWebKitMemory(on: webView)
    }
}
