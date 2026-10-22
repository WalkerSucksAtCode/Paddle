import Foundation
import JavaScriptCore
@testable import PaddleCore
import Testing
import WebKit

@MainActor
private final class AutofillPage: NSObject, WKNavigationDelegate, WKScriptMessageHandlerWithReply {
    static let world = WKContentWorld.world(name: ContactAutofillScript.worldName)
    let webView: WKWebView
    private var loaded: CheckedContinuation<Void, Never>?

    /// A web view with the page script as Paddle installs it, plus `__probe(id)`: the ids `fillable` returns for
    /// that field's form.
    override init() {
        let config = WKWebViewConfiguration()
        let probe = ContactAutofillScript.source.replacingOccurrences(
            of: "window.__paddleContactAutofill = true;",
            with: "window.__paddleContactAutofill = true; window.__probe = (id) => fillable(document.getElementById(id)).map(f => f.id);"
        )
        config.userContentController.addUserScript(WKUserScript(
            source: probe, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: Self.world
        ))
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        super.init()
        config.userContentController.addScriptMessageHandler(self, contentWorld: Self.world, name: ContactAutofillScript.handlerName)
        webView.navigationDelegate = self
    }

    func load(_ html: String, baseURL: String) async {
        await withCheckedContinuation { continuation in
            loaded = continuation
            webView.loadHTMLString(html, baseURL: URL(string: baseURL))
        }
    }

    func probe(_ id: String) async throws -> [String]? {
        try await webView.callAsyncJavaScript(
            "return window.__probe ? window.__probe(id) : null", arguments: ["id": id], in: nil, contentWorld: Self.world
        ) as? [String]
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded?.resume()
        loaded = nil
    }

    func userContentController(
        _ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
        replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
    ) {
        replyHandler(nil, nil)
    }
}

struct ContactAutofillTests {
    private func classify(_ field: [String: String]) throws -> String? {
        let context = try #require(JSContext())
        context.evaluateScript(ContactAutofillScript.classifierSource)
        let result = context.objectForKeyedSubscript("__paddleClassify").call(withArguments: [field])
        return result?.isNull == false && result?.isUndefined == false ? result?.toString() : nil
    }

    @Test func autocompleteTokensWin() throws {
        #expect(try classify(["autocomplete": "shipping given-name", "name": "fld1"]) == "givenName")
        #expect(try classify(["autocomplete": "email", "type": "text"]) == "email")
        #expect(try classify(["autocomplete": "address-level2"]) == "city")
        #expect(try classify(["autocomplete": "postal-code", "type": "text"]) == "postalCode")
        #expect(try classify(["autocomplete": "street-address", "tag": "textarea"]) == "streetAddress")
    }

    @Test func namesAndLabelsWhenThereIsNoAutocomplete() throws {
        #expect(try classify(["type": "text", "name": "first_name"]) == "givenName")
        #expect(try classify(["type": "text", "id": "lastName"]) == "familyName")
        #expect(try classify(["type": "text", "name": "name"]) == "name")
        #expect(try classify(["type": "tel", "name": "x"]) == "tel")
        #expect(try classify(["type": "text", "label": "Mobile number"]) == "tel")
        #expect(try classify(["type": "text", "placeholder": "ZIP code"]) == "postalCode")
        #expect(try classify(["type": "text", "name": "address2"]) == "addressLine2")
        #expect(try classify(["type": "text", "name": "street"]) == "addressLine1")
        #expect(try classify(["type": "text", "name": "company_name"]) == "organization")
        #expect(try classify(["tag": "select", "name": "state"]) == "region")
        #expect(try classify(["type": "text", "label": "City"]) == "city")
    }

    @Test func passwordsCardsAndOtherFieldsAreNeverContactFields() throws {
        #expect(try classify(["type": "password", "name": "email"]) == nil)
        #expect(try classify(["autocomplete": "cc-number", "name": "name"]) == nil)
        #expect(try classify(["autocomplete": "current-password"]) == nil)
        #expect(try classify(["type": "text", "name": "cardholder_name"]) == nil)
        #expect(try classify(["type": "text", "name": "username"]) == nil)
        #expect(try classify(["type": "search", "name": "q"]) == nil)
        #expect(try classify(["type": "text", "name": "coupon"]) == nil)
        #expect(try classify(["type": "text", "name": "message"]) == nil)
    }

    @Test func pageScriptParses() throws {
        let context = try #require(JSContext())
        var failure: String?
        context.exceptionHandler = { _, error in failure = error?.toString() }
        context.setObject(ContactAutofillScript.source, forKeyedSubscript: "src" as NSString)
        context.evaluateScript("new Function(src)")
        #expect(failure == nil)
    }

    /// In real WebKit, only fields a person can see get filled: not ones moved off screen, clipped, covered by other
    /// content, faded out through their ancestors, with see-through text, below the window or already filled. A field
    /// under its own label still counts.
    @MainActor
    @Test func onlyFieldsVisibleOnScreenAreFillable() async throws {
        let page = AutofillPage()
        let html = """
        <style>* { box-sizing: border-box; margin: 0 } input { display: block; width: 200px; height: 24px }</style>
        <form>
          <input id="name" autocomplete="name">
          <input id="email" type="email">
          <input id="offscreen" autocomplete="tel" style="position: absolute; left: -9999px">
          <div style="overflow: hidden; width: 10px; height: 10px"><input id="clipped" autocomplete="street-address" style="margin-left: 100px"></div>
          <input id="covered" autocomplete="postal-code" style="position: absolute; top: 400px; left: 0">
          <div style="position: absolute; top: 390px; left: 0; width: 300px; height: 50px; background: white"></div>
          <div style="opacity: .3"><div style="opacity: .3"><input id="faded" autocomplete="organization"></div></div>
          <input id="clear" autocomplete="address-level2" style="color: transparent">
          <input id="below" autocomplete="country" style="position: absolute; top: 2000px">
          <input id="filled" autocomplete="family-name" value="Lovelace">
          <div style="position: relative"><input id="floated" autocomplete="address-level1">
            <label for="floated" style="position: absolute; left: 0; top: 0; width: 200px; height: 24px">State</label></div>
        </form>
        """
        await page.load(html, baseURL: "https://autofill.test/")
        #expect(try await page.probe("name") == ["name", "email", "floated"])

        // A plain-http page never gets the script.
        await page.load(html, baseURL: "http://autofill.test/")
        #expect(try await page.probe("name") == nil)
    }

    @Test func replyCarriesOnlyAskedForNonEmptyValues() {
        let card = ContactCard(givenName: " Ada ", familyName: "Lovelace", email: "ada@example.com", addressLine1: "1 Main St", addressLine2: "Apt 2", city: "London")
        #expect(card.fullName == "Ada Lovelace")
        #expect(card.reply(for: ["name", "email", "tel", "bogus"]) == ["name": "Ada Lovelace", "email": "ada@example.com"])
        #expect(card.value(for: .streetAddress) == "1 Main St\nApt 2")
        #expect(card.summary == "Ada Lovelace · ada@example.com · London")
        #expect(ContactCard().isEmpty && !card.isEmpty)
        let data = try? JSONEncoder().encode(card)
        #expect(data.flatMap { try? JSONDecoder().decode(ContactCard.self, from: $0) } == card)
    }
}
