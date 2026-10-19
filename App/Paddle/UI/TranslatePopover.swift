import AppKit
import PaddleCore
import SwiftUI
import Translation
import WebKit

/// A translation popover offering web page translation (via Google Translate proxy)
/// and on-device text / article translation using macOS's Translation framework.
struct TranslatePopover: View {
    let tab: Tab
    let model: BrowserModel
    @Environment(\.chromeTheme) private var theme
    @State private var targetLanguage: String = {
        let code = Locale.current.language.languageCode?.identifier ?? "en"
        return code.isEmpty ? "en" : code
    }()
    @State private var showAppleTranslation = false
    @State private var textToTranslate = ""

    static let supportedLanguages: [(name: String, code: String)] = [
        ("English", "en"),
        ("Spanish", "es"),
        ("French", "fr"),
        ("German", "de"),
        ("Chinese (Simplified)", "zh-CN"),
        ("Chinese (Traditional)", "zh-TW"),
        ("Japanese", "ja"),
        ("Korean", "ko"),
        ("Italian", "it"),
        ("Portuguese", "pt"),
        ("Russian", "ru"),
        ("Arabic", "ar"),
        ("Hindi", "hi"),
        ("Dutch", "nl"),
        ("Polish", "pl"),
        ("Swedish", "sv"),
        ("Turkish", "tr"),
        ("Ukrainian", "uk"),
        ("Vietnamese", "vi")
    ]

    var isAlreadyTranslated: Bool {
        guard let url = tab.url else { return false }
        return url.host?.contains("translate.goog") == true || url.host?.contains("translate.google.com") == true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "translate")
                    .foregroundStyle(theme?.accent ?? Color.accentColor)
                    .imageScale(.medium)
                Text("Translate Page")
                    .chromeFont(size: 13, weight: .semibold)
                Spacer()
            }

            if isAlreadyTranslated {
                VStack(alignment: .leading, spacing: 8) {
                    Text("This page is currently translated.")
                        .chromeFont(size: 11)
                        .foregroundStyle(.secondary)
                    Button("Show Original Page") {
                        revertToOriginal()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Translate to:")
                            .chromeFont(size: 12)
                        Spacer()
                        Picker("", selection: $targetLanguage) {
                            ForEach(Self.supportedLanguages, id: \.code) { lang in
                                Text(lang.name).tag(lang.code)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 160)
                    }

                    HStack(spacing: 8) {
                        Button {
                            translateWebPage()
                        } label: {
                            Label("Translate Webpage", systemImage: "globe")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)

                        Button {
                            openInDeepL()
                        } label: {
                            Text("DeepL")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Translate with DeepL")
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Apple Translation")
                    .chromeFont(size: 11, weight: .medium)
                    .foregroundStyle(.secondary)

                Button {
                    extractSelectionOrSummaryAndTranslate()
                } label: {
                    Label("Translate Selected Text / Summary", systemImage: "character.bubble")
                        .chromeFont(size: 12)
                }
                .buttonStyle(.borderless)
                .help("Translate selected passage or article summary with Apple's private on-device translation")
            }
        }
        .padding(14)
        .frame(width: 300)
        .translationPresentation(isPresented: $showAppleTranslation, text: textToTranslate)
    }

    private func translateWebPage() {
        guard let url = tab.url else { return }
        tab.showTranslatePopover = false
        let encoded = url.absoluteString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? url.absoluteString
        if let target = URL(string: "https://translate.google.com/translate?sl=auto&tl=\(targetLanguage)&u=\(encoded)") {
            tab.load(target)
        }
    }

    private func openInDeepL() {
        guard let url = tab.url else { return }
        tab.showTranslatePopover = false
        let encoded = url.absoluteString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? url.absoluteString
        if let target = URL(string: "https://www.deepl.com/translator#auto/\(targetLanguage)/\(encoded)") {
            tab.load(target)
        }
    }

    private func revertToOriginal() {
        tab.showTranslatePopover = false
        guard let url = tab.url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItem = components.queryItems?.first(where: { $0.name == "u" }),
              let origString = queryItem.value,
              let origURL = URL(string: origString) else {
            tab.reload()
            return
        }
        tab.load(origURL)
    }

    private func extractSelectionOrSummaryAndTranslate() {
        if let article = tab.readerArticle {
            textToTranslate = "\(article.title)\n\n\(article.excerpt)"
            showAppleTranslation = true
            return
        }
        guard let webView = tab.webView else { return }
        webView.evaluateJavaScript("window.getSelection().toString()", in: nil, in: .defaultClient) { result in
            if case .success(let val) = result, let str = val as? String, !str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self.textToTranslate = str
                self.showAppleTranslation = true
            } else {
                let probe = "document.title + '\\n\\n' + (document.querySelector('meta[name=\"description\"]')?.content || '')"
                webView.evaluateJavaScript(probe, in: nil, in: .defaultClient) { res in
                    if case .success(let text) = res, let titleAndDesc = text as? String, !titleAndDesc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        self.textToTranslate = titleAndDesc
                        self.showAppleTranslation = true
                    }
                }
            }
        }
    }
}
