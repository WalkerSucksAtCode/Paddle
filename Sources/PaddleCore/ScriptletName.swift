import Foundation

/// The scriptlets Paddle implements (`ScriptletLibrary`), by uBlock Origin's canonical name. A filter line's
/// `##+js(name, …)` names one of these or an alias (`ScriptletParser`); any other name is refused, so a list can
/// only choose among Paddle's own scripts and pass them strings.
public enum ScriptletName: String, CaseIterable, Sendable, Codable {
    case setConstant = "set-constant"
    case abortOnPropertyRead = "abort-on-property-read"
    case abortOnPropertyWrite = "abort-on-property-write"
    case abortCurrentScript = "abort-current-script"
    case abortOnStackTrace = "abort-on-stack-trace"
    case noSetTimeoutIf = "no-setTimeout-if"
    case noSetIntervalIf = "no-setInterval-if"
    case addEventListenerDefuser = "addEventListener-defuser"
    case jsonPrune = "json-prune"
    case jsonPruneFetchResponse = "json-prune-fetch-response"
    case jsonPruneXHRResponse = "json-prune-xhr-response"
    case noFetchIf = "no-fetch-if"
    case noXHRIf = "no-xhr-if"
    case noEvalIf = "noeval-if"
    case noWindowOpenIf = "no-window-open-if"
    case removeAttr = "remove-attr"
    case removeClass = "remove-class"
    case removeNodeText = "remove-node-text"
    case nanoSetIntervalBooster = "nano-setInterval-booster"
    case nanoSetTimeoutBooster = "nano-setTimeout-booster"
    case noWebRTC = "nowebrtc"
}
