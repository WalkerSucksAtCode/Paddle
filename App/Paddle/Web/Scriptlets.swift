import Foundation
import ObjectiveC
import PaddleCore
import WebKit

/// List scriptlets (`ScriptletSet` / `ScriptletLibrary`) as page-world document-start user scripts,
/// every frame.
///
/// A rule with sites becomes one script WebKit injects only on those sites (private match-pattern
/// `WKUserScript` init): a page pays only for its own scriptlets (~+6 MB per process for 6,600 scripts,
/// vs +46 MB for one combined script). `site.*` entities, which match patterns can't express, share a
/// dispatcher that checks the hostname; so does every rule if that initializer is missing.
/// `contentBlocking: false` sites are excluded from all of them.
enum Scriptlets {
    struct Built {
        var scripts: [WKUserScript] = []
        /// Rules given their own match-pattern script.
        var matched = 0
        /// Rules run by the dispatcher.
        var dispatched = 0
    }

    private static let initSelector = NSSelectorFromString(
        "_initWithSource:injectionTime:forMainFrameOnly:includeMatchPatternStrings:excludeMatchPatternStrings:associatedURL:contentWorld:"
    )
    static let supportsMatchPatterns = WKUserScript.instancesRespond(to: initSelector)

    static func build(_ rules: [ScriptletRule], blockingOffHosts: [String]) -> Built {
        var built = Built()
        var dispatched: [ScriptletRule] = []
        let off = blockingOffHosts.map(pattern)
        for rule in rules {
            guard supportsMatchPatterns, !rule.includeDomains.isEmpty || rule.isGeneric else {
                dispatched.append(dispatchRule(rule, blockingOffHosts: blockingOffHosts))
                continue
            }
            let include = rule.isGeneric ? ["*://*/*"] : rule.includeDomains.map(pattern)
            let exclude = rule.excludeDomains.map(pattern) + off
            // Entity exclusions can't be patterns: such a rule runs through the dispatcher instead.
            if rule.excludeEntities.isEmpty,
               let script = matchPatternScript(ScriptletLibrary.source(for: rule.name, arguments: rule.arguments), include: include, exclude: exclude) {
                built.scripts.append(script)
                built.matched += 1
            } else {
                var whole = rule
                whole.includeEntities = []
                if !whole.includeDomains.isEmpty || rule.isGeneric { dispatched.append(dispatchRule(whole, blockingOffHosts: blockingOffHosts)) }
            }
            // The same rule's `site.*` entities, if any, go to the dispatcher.
            if !rule.includeEntities.isEmpty {
                var entities = rule
                entities.includeDomains = []
                dispatched.append(dispatchRule(entities, blockingOffHosts: blockingOffHosts))
            }
        }
        if !dispatched.isEmpty {
            built.scripts.append(WKUserScript(
                source: ScriptletLibrary.dispatcherSource(for: dispatched), injectionTime: .atDocumentStart,
                forMainFrameOnly: false, in: .page
            ))
            built.dispatched = dispatched.count
        }
        return built
    }

    /// `*://*.example.com/*`: the host and its subdomains, over http and https.
    private static func pattern(_ host: String) -> String { "*://*.\(host)/*" }

    private static func dispatchRule(_ rule: ScriptletRule, blockingOffHosts: [String]) -> ScriptletRule {
        var rule = rule
        for host in blockingOffHosts where !rule.excludeDomains.contains(host) { rule.excludeDomains.append(host) }
        return rule
    }

    /// `-[WKUserScript _initWithSource:…]` with include and exclude match patterns, page world, document start, all
    /// frames; nil when WebKit doesn't have it or refuses.
    private static func matchPatternScript(_ source: String, include: [String], exclude: [String]) -> WKUserScript? {
        let allocSelector = NSSelectorFromString("alloc")
        guard supportsMatchPatterns,
              let initMethod = class_getInstanceMethod(WKUserScript.self, initSelector),
              let allocMethod = class_getClassMethod(WKUserScript.self, allocSelector) else { return nil }
        typealias Alloc = @convention(c) (AnyClass, Selector) -> Unmanaged<AnyObject>
        typealias Init = @convention(c) (
            Unmanaged<AnyObject>, Selector, NSString, Int, Bool, NSArray, NSArray, NSURL?, WKContentWorld
        ) -> Unmanaged<WKUserScript>?
        // `alloc` returns +1 and `init` consumes it, returning +1: Unmanaged on both sides keeps ARC out of it.
        let allocated = unsafeBitCast(method_getImplementation(allocMethod), to: Alloc.self)(WKUserScript.self, allocSelector)
        let made = unsafeBitCast(method_getImplementation(initMethod), to: Init.self)(
            allocated, initSelector, source as NSString, WKUserScriptInjectionTime.atDocumentStart.rawValue, false,
            include as NSArray, exclude as NSArray, nil, .page
        )
        return made?.takeRetainedValue()
    }
}
