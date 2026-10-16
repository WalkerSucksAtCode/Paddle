import Foundation
@testable import PaddleCore
import Testing

struct ThemeTests {
    @Test func builtInsPassContrastInBothModes() {
        #expect(BuiltInThemes.all.count == 6)
        for theme in BuiltInThemes.all {
            for (mode, palette) in [("light", theme.light), ("dark", theme.dark)] {
                #expect(palette != nil)
                let issues = palette.map { ThemeContrast.issues($0, highContrast: theme.isHighContrast) } ?? ["missing"]
                #expect(issues.isEmpty, "\(theme.name) \(mode): \(issues)")
                for key in ThemePalette.keys { #expect(palette?[key] != nil) }
            }
        }
    }

    @Test func hexRoundTripAndBadHex() {
        #expect(RGBColor(hex: "#1a2B3c")?.hex == "#1A2B3C")
        #expect(RGBColor(hex: "1A2B3C")?.hex == "#1A2B3C")
        for bad in ["", "#fff", "#12345", "#1234567", "#gggggg", "#+12345", "blue"] { #expect(RGBColor(hex: bad) == nil) }
    }

    @Test func contrastAndBlend() {
        #expect(abs(RGBColor.contrast(.black, .white) - 21) < 1e-9)
        #expect(RGBColor.contrast(.white, .white) == 1)
        #expect(RGBColor.black.blended(with: .white, amount: 0) == .black)
        #expect(RGBColor.black.blended(with: .white, amount: 1) == .white)
        #expect(abs(RGBColor.black.blended(with: .white, amount: 0.5).red - 0.5) < 1e-9)
        #expect(RGBColor(hex: "#FFFF00")!.bestText() == .black)
        #expect(RGBColor(hex: "#000033")!.bestText() == .white)
    }

    @Test func decodeWarnsOnBadColor() throws {
        let json = ##"{"light": {"toolbar": "red", "text": "#101010", "bogus": 1}, "dark": {"accent": "#abcdef"}}"##
        let (theme, warnings) = try ChromeTheme.decode(id: "mine", data: Data(json.utf8))
        #expect(theme.id == "mine" && theme.name == "mine" && !theme.isBuiltIn)
        #expect(theme.light?.toolbar == nil)
        #expect(theme.light?.text == RGBColor(hex: "#101010"))
        #expect(warnings == ["light.toolbar: not a #rrggbb color"])
        #expect(theme.dark?.accent?.hex == "#ABCDEF")
        let darkOnly = try ChromeTheme.decode(id: "d", data: Data(#"{"dark": {}}"#.utf8))
        #expect(darkOnly.theme.light == nil && darkOnly.theme.dark != nil)
    }

    @Test func encodeAndDecodeWithCustomName() throws {
        let palette = ThemePalette(tabStrip: RGBColor(hex: "#112233"), toolbar: RGBColor(hex: "#445566"))
        let theme = ChromeTheme(id: "custom-sunset", name: "Custom Sunset", light: palette, dark: palette)
        let data = try theme.encode()
        let (decoded, warnings) = try ChromeTheme.decode(id: "custom-sunset", data: data)
        #expect(warnings.isEmpty)
        #expect(decoded.name == "Custom Sunset")
        #expect(decoded.light?.tabStrip == RGBColor(hex: "#112233"))
        #expect(decoded.dark?.toolbar == RGBColor(hex: "#445566"))
    }

    @Test func nonObjectThrows() {
        #expect(throws: (any Error).self) { try ChromeTheme.decode(id: "x", data: Data("[1]".utf8)) }
        #expect(throws: (any Error).self) { try ChromeTheme.decode(id: "x", data: Data("nope".utf8)) }
    }

    @Test func contrastIssuesNameThePair() {
        let palette = ThemePalette(tabStrip: RGBColor(hex: "#777777"), toolbar: .white, text: RGBColor(hex: "#888888"))
        let issues = ThemeContrast.issues(palette, highContrast: false)
        #expect(issues.contains { $0.hasPrefix("text on tabStrip ") && $0.hasSuffix(":1, needs 4.5:1") })
        #expect(!issues.contains { $0.contains("selectedTab") })
    }

    @Test func tintIsCappedForReadability() {
        let base = DefaultChromeColors.darkBase
        let text = DefaultChromeColors.darkText
        let secondary = DefaultChromeColors.darkSecondary
        let yellow = ThemeContrast.maxTintStrength(
            base: base, tint: ColorPreset.yellow.color, text: text, secondaryText: secondary, requested: 1)
        #expect(yellow < 1 && yellow >= 0)
        let blue = ThemeContrast.maxTintStrength(
            base: base, tint: ColorPreset.blue.color, text: text, secondaryText: secondary, requested: 0.25)
        #expect(blue == 0.25)
    }

    @Test func colorChoiceParsing() {
        #expect(ColorChoice(configValue: "system", automaticValue: "system") == .automatic)
        #expect(ColorChoice(configValue: "none", automaticValue: "none") == .automatic)
        #expect(ColorChoice(configValue: "none", automaticValue: "system") == nil)
        #expect(ColorChoice(configValue: "Blue", automaticValue: "system") == .preset(.blue))
        #expect(ColorChoice(configValue: "#112233", automaticValue: "system") == .custom(RGBColor(hex: "#112233")!))
        #expect(ColorChoice(configValue: "nonsense", automaticValue: "system") == nil)
        #expect(ColorChoice.custom(RGBColor(hex: "#112233")!).configValue(automaticValue: "system") == "#112233")
        #expect(ColorChoice.preset(.pink).configValue(automaticValue: "none") == "pink")
    }

    @Test func configKeys() throws {
        let d = PaddleConfig()
        #expect(d.theme == "default" && d.accentColor == "system" && d.chromeTint == "none" && d.chromeTintStrength == 25)
        let good = try PaddleConfig.decode(Data(##"{"theme":"ocean","accentColor":"#aabbcc","chromeTint":"green","chromeTintStrength":500}"##.utf8))
        #expect(good.theme == "ocean" && good.accentColor == "#aabbcc" && good.chromeTint == "green" && good.chromeTintStrength == 100)
        #expect(try PaddleConfig.decode(Data(#"{"chromeTintStrength":-5}"#.utf8)).chromeTintStrength == 0)
        let bad = try PaddleConfig.decodeReportingIssues(Data(#"{"accentColor":"nope","chromeTint":"system","theme":3}"#.utf8))
        #expect(bad.config.accentColor == "system" && bad.config.chromeTint == "none" && bad.config.theme == "default")
        #expect(Set(bad.issues.map(\.key)) == [.accentColor, .chromeTint, .theme])
        #expect(try PaddleConfig.decode(good.encoded()) == good)
    }

    @Test func accessibilityAndCustomizationConfigKeys() throws {
        let d = PaddleConfig()
        #expect(!d.underlineLinks && !d.alwaysShowTabCloseButtons && !d.showHomeButton && !d.alwaysShowDownloadsButton)
        let json = """
        {"underlineLinks": true, "alwaysShowTabCloseButtons": true, "showHomeButton": true, "alwaysShowDownloadsButton": true}
        """
        let config = try PaddleConfig.decode(Data(json.utf8))
        #expect(config.underlineLinks && config.alwaysShowTabCloseButtons && config.showHomeButton && config.alwaysShowDownloadsButton)
        #expect(try PaddleConfig.decode(config.encoded()) == config)
    }
}
