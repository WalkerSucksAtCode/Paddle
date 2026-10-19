import Foundation
@testable import PaddleCore
import Testing

struct MosaicIconTests {
    @Test func onlySymbolLikeNamesAreIcons() {
        #expect(MosaicIcon("star.fill")?.name == "star.fill")
        #expect(MosaicIcon("rectangle.split.2x2") != nil)
        for name in ["", "Star", "../x", "star fill", ".star", "star.", "🎨"] {
            #expect(MosaicIcon(name) == nil, "\(name)")
        }
    }

    @Test func layoutSavesItsIconAndTintAndKeepsThemThroughChanges() throws {
        var layout = try #require(PaneLayout("a", "b"))
        layout.icon = MosaicIcon("cart.fill")
        layout.iconTint = .green
        let data = try JSONEncoder().encode(layout)
        let back = try JSONDecoder().decode(PaneLayout.self, from: data)
        #expect(back.icon?.name == "cart.fill" && back.iconTint == .green && back == layout)
        #expect(layout.arranged(.rows).icon == layout.icon && layout.rotated().iconTint == .green)
        #expect(layout.mapped { $0 + "x" }?.icon == layout.icon)
        let odd = #"{"axis":"horizontal","ratio":0.5,"first":{"tab":"a"},"second":{"tab":"b"},"icon":"Bad Name","iconTint":"Mauve"}"#
        let lenient = try JSONDecoder().decode(PaneLayout.self, from: Data(odd.utf8))
        #expect(lenient.icon == nil && lenient.iconTint == nil)
        let plain = try #require(PaneLayout("a", "b"))
        #expect(!String(decoding: try JSONEncoder().encode(plain), as: UTF8.self).contains("icon"))
    }

    @Test func symbolSearchRanksNamesBeforeKeywordsAndDropsLocalizedVariants() {
        let catalog = SymbolCatalog(
            order: ["cart", "cart.fill", "bag", "character", "character.ar", "star", "creditcard"],
            categories: ["cart": ["commerce"], "cart.fill": ["commerce"], "bag": ["commerce"], "star": ["shapes"]],
            keywords: ["bag": ["shopping"], "cart": ["shopping"], "creditcard": ["shop", "pay"]],
            categoryKeys: ["all", "whatsnew", "commerce", "shapes", "math"]
        )
        #expect(!catalog.entries.contains { $0.name == "character.ar" })
        #expect(catalog.categories == ["commerce", "shapes"])
        #expect(catalog.search("cart") == ["cart", "cart.fill"])
        #expect(catalog.search("fill") == ["cart.fill"])
        #expect(catalog.search("shop") == ["cart", "bag", "creditcard"])
        #expect(catalog.search("shopping", category: "commerce") == ["cart", "bag"])
        #expect(catalog.search("cart fill") == ["cart.fill"])
        #expect(catalog.search("", category: "shapes") == ["star"])
        #expect(catalog.search("zzz").isEmpty)
        // Nothing typed, no category: suggested symbols the catalog has lead, then the rest in order.
        let mixed = SymbolCatalog(order: ["0.circle", "cart", "star.fill", "bag"], categories: [:], keywords: [:], categoryKeys: [])
        #expect(mixed.search("") == ["star.fill", "0.circle", "cart", "bag"])
    }

    @Test func systemCatalogLoadsWhenPresent() throws {
        guard let catalog = SymbolCatalog.load() else { return }
        #expect(catalog.entries.count > 1000)
        #expect(catalog.search("star").first == "star")
        #expect(!catalog.categories.isEmpty)
    }
}
