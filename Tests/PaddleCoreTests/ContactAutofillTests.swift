import Foundation
import JavaScriptCore
@testable import PaddleCore
import Testing

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
