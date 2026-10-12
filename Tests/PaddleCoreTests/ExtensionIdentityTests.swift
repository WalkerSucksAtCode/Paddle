import Foundation
@testable import PaddleCore
import Testing

struct ExtensionIdentityTests {
    private func isLowerHex32(_ s: String) -> Bool {
        s.count == 32 && s.allSatisfy { $0.isASCII && ($0.isNumber || ("a"..."f").contains($0)) }
    }

    @Test func stableForSameNameAndSalt() {
        #expect(ExtensionIdentity.identifier(forFolder: "ubolite", salt: "s") == ExtensionIdentity.identifier(forFolder: "ubolite", salt: "s"))
    }

    @Test func differsAcrossSaltsAndNames() {
        let base = ExtensionIdentity.identifier(forFolder: "ubolite", salt: "s1")
        #expect(base != ExtensionIdentity.identifier(forFolder: "ubolite", salt: "s2"))
        #expect(base != ExtensionIdentity.identifier(forFolder: "bitwarden", salt: "s1"))
    }

    @Test func identifierIs32LowercaseHex() {
        #expect(isLowerHex32(ExtensionIdentity.identifier(forFolder: "Ünïcode folder", salt: "salt")))
    }

    @Test func saltIs32LowercaseHexAndRandom() {
        let a = ExtensionIdentity.makeSalt(), b = ExtensionIdentity.makeSalt()
        #expect(isLowerHex32(a) && isLowerHex32(b))
        #expect(a != b)
    }

    @Test func baseURLHasSchemeAndHost() {
        let id = ExtensionIdentity.identifier(forFolder: "x", salt: "s")
        let url = ExtensionIdentity.baseURL(for: id)
        #expect(url.scheme == "webkit-extension")
        #expect(url.host == id)
        #expect(url.absoluteString == "webkit-extension://\(id)/")
    }

    @Test func identifierOfURLRoundTripsAndRejectsOthers() {
        let id = ExtensionIdentity.identifier(forFolder: "x", salt: "s")
        #expect(ExtensionIdentity.identifier(of: ExtensionIdentity.baseURL(for: id)) == id)
        #expect(ExtensionIdentity.identifier(of: URL(string: "webkit-extension://\(id)/options.html?a=1")) == id)
        #expect(ExtensionIdentity.identifier(of: URL(string: "https://example.com/")) == nil)
        #expect(ExtensionIdentity.identifier(of: URL(string: "http://\(id)/")) == nil)
        #expect(ExtensionIdentity.identifier(of: nil) == nil)
    }

    @Test func extensionsMayOpenWebPagesBlankAndTheirOwnPagesOnly() {
        let id = ExtensionIdentity.identifier(forFolder: "x", salt: "s")
        let other = ExtensionIdentity.identifier(forFolder: "y", salt: "s")
        func may(_ string: String, _ from: String? = id) -> Bool {
            ExtensionIdentity.extensionMayOpen(URL(string: string)!, extensionID: from)
        }
        #expect(may("https://example.com/"))
        #expect(may("HTTP://example.com/"))
        #expect(may("about:blank"))
        #expect(may("webkit-extension://\(id)/options.html"))
        #expect(!may("webkit-extension://\(other)/options.html"))
        #expect(!may("webkit-extension://\(id)/options.html", nil))
        #expect(!may("file:///Users/Walker/Library/Application%20Support/Paddle/session.json"))
        #expect(!may("about:config"))
        #expect(!may("data:text/html,hi"))
        #expect(!may("javascript:alert(1)"))
        #expect(!may("x-apple.systempreferences:"))
    }

    // MARK: - Personas

    @Test func chromeAlphabetMapsHexDigitsToAThroughP() {
        #expect(ExtensionIdentity.chromeID(hex: "0123456789abcdef") == "abcdefghijklmnop")
        #expect(ExtensionIdentity.chromeID(hex: "FEDCBA") == "ponmlk")
        #expect(ExtensionIdentity.chromeID(hex: "0g") == nil)
        #expect(ExtensionIdentity.chromeID(hex: "16c4e4dbfe721f2a74a46a0fd6ecbcb6") == "bgmeoenlpohcbpckhekegkapngomlmlg")
    }

    /// Chromium's `id_util_unittest` vector (GenerateId over the bytes of "test"), and a real store extension:
    /// Google Docs Offline's manifest `key` gives its Web Store id.
    @Test func publicKeyGivesChromesID() {
        #expect(ExtensionIdentity.chromeID(publicKeyDER: Data("test".utf8)) == "jpignaibiiemhngfjkcpokkamffknabf")
        let docsOffline = """
        MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAnF7RGLAxIon0/XeNZ4MLdP3DMkoORzEAKVg0sb89JpA/W2osTHr91Wqwdc9lW0mFcSpCYS9Y3e7cUMFo/M2ETASIuZncMiUzX2/0rrWtGQ3UuEj3KSe5PdaVZfisyJw/FebvHwirEWrhqcgzVUj9fL9YjE0G45d1zMKcc1umKvLqPyTznNuKBZ9GJREdGLRJCBmUgCkI8iwtwC+QZTUppmaD50/ksnEUXv+QkgGN07/KoNA5oAgo49Jf1XBoMv4QXtVZQlBYZl84zAsI82hb63a6Gu29U/4qMWDdI7+3Ne5TRvo6Zi3EI4M2NQNplJhik105qrz+eTLJJxvf4slrWwIDAQAB
        """
        #expect(ExtensionIdentity.chromeID(manifestKey: docsOffline) == "ghbmnnjooekpmoecnnnilnnbdlolhkhi")
        #expect(ExtensionIdentity.chromeID(manifestKey: "not base64!") == nil)
    }

    @Test func mozHostIsTheSaltedIDAsAUUID() {
        #expect(ExtensionIdentity.mozHost(hex: "16c4e4dbfe721f2a74a46a0fd6ecbcb6") == "16c4e4db-fe72-1f2a-74a4-6a0fd6ecbcb6")
        #expect(ExtensionIdentity.mozHost(hex: "16C4E4DBFE721F2A74A46A0FD6ECBCB6") == "16c4e4db-fe72-1f2a-74a4-6a0fd6ecbcb6")
        #expect(ExtensionIdentity.mozHost(hex: "abc") == nil)
        #expect(ExtensionIdentity.mozHost(hex: "zzc4e4dbfe721f2a74a46a0fd6ecbcb6") == nil)
    }

    /// Firefox: sha1 of the gecko id (Proton Pass's hash as computed in the 4c-0 probe, E22).
    @Test func redirectURLFormulas() throws {
        let proton = "78272b6fa58f4a1abaac99321d503a20@proton.me"
        #expect(ExtensionIdentity.firefoxRedirectHash(addonID: proton) == "70b65e009a0284959b0422466b9541d3931679de")
        #expect(ExtensionIdentity.firefoxRedirectURL(addonID: proton)?.absoluteString == "https://70b65e009a0284959b0422466b9541d3931679de.extensions.allizom.org/")
        #expect(ExtensionIdentity.firefoxRedirectURL(addonID: proton, path: "/cb")?.absoluteString == "https://70b65e009a0284959b0422466b9541d3931679de.extensions.allizom.org/cb")
        #expect(ExtensionIdentity.firefoxLoopbackRedirect(addonID: proton) == "http://127.0.0.1/mozoauth2/70b65e009a0284959b0422466b9541d3931679de")
        func allowed(_ s: String) throws -> Bool { ExtensionIdentity.firefoxRedirectAllowed(try #require(URL(string: s)), addonID: proton) }
        #expect(try allowed("https://70b65e009a0284959b0422466b9541d3931679de.extensions.allizom.org/x?code=1"))
        #expect(try allowed("http://127.0.0.1:8123/mozoauth2/70b65e009a0284959b0422466b9541d3931679de?code=1"))
        #expect(try allowed("http://127.0.0.1/mozoauth2/70b65e009a0284959b0422466b9541d3931679de/sub"))
        #expect(try !allowed("http://127.0.0.1/mozoauth2/70b65e009a0284959b0422466b9541d3931679deX"))
        #expect(try !allowed("http://70b65e009a0284959b0422466b9541d3931679de.extensions.allizom.org/"))
        #expect(try !allowed("https://evil.example/mozoauth2/70b65e009a0284959b0422466b9541d3931679de"))
        #expect(ExtensionIdentity.chromeRedirectURL(id: "abcdefghijklmnopabcdefghijklmnop", path: "cb")?.absoluteString == "https://abcdefghijklmnopabcdefghijklmnop.chromiumapp.org/cb")
    }

    @Test func extensionSchemesAreRecognised() {
        for scheme in ["webkit-extension", "chrome-extension", "moz-extension", "safari-web-extension", "MOZ-EXTENSION"] {
            #expect(ExtensionIdentity.identifier(of: URL(string: "\(scheme)://host-1/p.html")) == "host-1")
        }
        #expect(ExtensionIdentity.identifier(of: URL(string: "ms-browser-extension://x/")) == nil)
    }

    @Test func mayOpenComparesSchemeAndHostWithTheBaseURL() throws {
        let moz = try #require(URL(string: "moz-extension://16c4e4db-fe72-1f2a-74a4-6a0fd6ecbcb6/"))
        func may(_ s: String, _ base: URL?) throws -> Bool { ExtensionIdentity.extensionMayOpen(try #require(URL(string: s)), baseURL: base) }
        #expect(try may("moz-extension://16c4e4db-fe72-1f2a-74a4-6a0fd6ecbcb6/options.html", moz))
        #expect(try !may("webkit-extension://16c4e4db-fe72-1f2a-74a4-6a0fd6ecbcb6/options.html", moz))
        #expect(try !may("moz-extension://00000000-fe72-1f2a-74a4-6a0fd6ecbcb6/options.html", moz))
        #expect(try may("https://example.com/", moz))
        #expect(try !may("moz-extension://16c4e4db-fe72-1f2a-74a4-6a0fd6ecbcb6/options.html", nil))
        // The id-only form stays webkit-extension only.
        #expect(!ExtensionIdentity.extensionMayOpen(URL(string: "chrome-extension://abc/x.html")!, extensionID: "abc"))
    }

    @Test func resolvePicksSchemeHostAndIDPerPersona() throws {
        let salted = "16c4e4dbfe721f2a74a46a0fd6ecbcb6"
        let none = ExtensionIdentity.resolve(persona: .none, saltedID: salted, manifest: [:])
        #expect(none.baseURL.absoluteString == "webkit-extension://\(salted)/" && none.runtimeID == salted)
        #expect(ExtensionIdentity.resolve(persona: .native, saltedID: salted, manifest: [:]) == none)

        let firefox = ExtensionIdentity.resolve(persona: .firefox, saltedID: salted, manifest: [:])
        #expect(firefox.runtimeID == salted)
        #expect(firefox.baseURL.absoluteString == "moz-extension://16c4e4db-fe72-1f2a-74a4-6a0fd6ecbcb6/")

        let store = "mnjggcdmjocbbbhaepdhchncahnbgone"
        let chrome = ExtensionIdentity.resolve(persona: .chrome, saltedID: salted, manifest: [:], storeID: store)
        #expect(chrome.runtimeID == "bgmeoenlpohcbpckhekegkapngomlmlg" && !chrome.isPublic)
        #expect(chrome.baseURL.absoluteString == "chrome-extension://bgmeoenlpohcbpckhekegkapngomlmlg/")

        // Store installs that need their id for sign-in or website messaging, or with publicID, use the store id.
        for manifest: [String: Any] in [["permissions": ["identity"]], ["oauth2": [:]], ["externally_connectable": [:]]] {
            #expect(ExtensionIdentity.resolve(persona: .chrome, saltedID: salted, manifest: manifest, storeID: store).runtimeID == store)
        }
        let forced = ExtensionIdentity.resolve(persona: .chrome, saltedID: salted, manifest: [:], storeID: store, publicID: true)
        #expect(forced.runtimeID == store && forced.isPublic)

        // A sideloaded manifest key counts only with publicID.
        let key = ["key": "MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQCrKfMnLqViEyokd1wk57FxJtW2XXpGXzIHBzv9vQI/01UsuP0IV5/lj0wx7zJ/xcibUgDeIxobvv9XD+zO1MdjMWuqJFcKuSS4Suqkje6u+pMrTSGOSHq1bmBVh0kpToN8YoJs/P/yrRd7FEtAXTaFTGxQL4C385MeXSjaQfiRiQIDAQAB", "oauth2": [:]] as [String: Any]
        #expect(ExtensionIdentity.resolve(persona: .chrome, saltedID: salted, manifest: key).isPublic == false)
        #expect(ExtensionIdentity.resolve(persona: .chrome, saltedID: salted, manifest: key, publicID: true).runtimeID == "nmmhkkegccagdldgiimedpiccmgmieda")
    }

    @Test func privateHostsAndRebasingForSessionRewrite() throws {
        let salted = "16c4e4dbfe721f2a74a46a0fd6ecbcb6"
        #expect(ExtensionIdentity.privateHosts(saltedID: salted) == [salted, "bgmeoenlpohcbpckhekegkapngomlmlg", "16c4e4db-fe72-1f2a-74a4-6a0fd6ecbcb6"])
        let old = try #require(URL(string: "webkit-extension://\(salted)/popup.html?x=1#y"))
        let base = ExtensionIdentity.resolve(persona: .firefox, saltedID: salted, manifest: [:]).baseURL
        #expect(ExtensionIdentity.rebased(old, onto: base)?.absoluteString == "moz-extension://16c4e4db-fe72-1f2a-74a4-6a0fd6ecbcb6/popup.html?x=1#y")
        for name in [salted, "bgmeoenlpohcbpckhekegkapngomlmlg", "16c4e4db-fe72-1f2a-74a4-6a0fd6ecbcb6"] {
            #expect(ExtensionIdentity.looksLikeExtensionHost(name), "\(name)")
        }
        for name in ["example.com", "16C4E4DBFE721F2A74A46A0FD6ECBCB6", "bgmeoenlpohcbpckhekegkapngomlmq"] {
            #expect(!ExtensionIdentity.looksLikeExtensionHost(name), "\(name)")
        }
    }

    @Test func installRecordsSayInstallOnceAndSeedFromPermissionRecords() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000.5)
        var installs = ExtensionInstalls.seeded(folders: ["protonpass"], now: now)
        #expect(installs.installReason(folder: "protonpass") == nil)
        #expect(installs.installReason(folder: "new") == "install")
        let first = installs.markSeen(folder: "new", now: now)
        let second = installs.markSeen(folder: "new", now: now.addingTimeInterval(60))
        #expect(first && !second)
        #expect(installs.installReason(folder: "new") == nil)
        let pruned = installs.prune(keeping: ["new"])
        #expect(pruned && installs.firstSeen.keys.sorted() == ["new"])
        let round = try ExtensionInstalls.decode(installs.encoded())
        #expect(round.firstSeen["new"] == Date(timeIntervalSince1970: 1_790_000_000))
    }

    @Test func priorStorageIDsCoverEveryPersonaSwitch() {
        let hex = "16c4e4dbfe721f2a74a46a0fd6ecbcb6"
        let chrome = ExtensionIdentity.chromeID(hex: hex)!
        // Firefox (hex) → chrome: the hex storage moves to the a–p id.
        #expect(ExtensionIdentity.priorStorageIDs(saltedID: hex, current: chrome) == [hex])
        // Chrome → firefox or none: back from the a–p id.
        #expect(ExtensionIdentity.priorStorageIDs(saltedID: hex, current: hex) == [chrome])
        // A public store id toggled on, then off.
        let store = String(repeating: "a", count: 32)
        #expect(ExtensionIdentity.priorStorageIDs(saltedID: hex, publicIDs: [store], current: store) == [hex, chrome])
        #expect(ExtensionIdentity.priorStorageIDs(saltedID: hex, publicIDs: [store], current: chrome) == [hex, store])
    }
}
