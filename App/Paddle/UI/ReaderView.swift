import PaddleCore
import SwiftUI
import WebKit

enum ReaderTheme: String, CaseIterable, Identifiable {
    case system, light, sepia, dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .sepia: "Sepia"
        case .dark: "Dark"
        }
    }

    var backgroundColor: String {
        switch self {
        case .system: "Canvas"
        case .light: "#ffffff"
        case .sepia: "#fbf0d9"
        case .dark: "#202124"
        }
    }

    var textColor: String {
        switch self {
        case .system: "CanvasText"
        case .light: "#1a1a1a"
        case .sepia: "#3d2b1f"
        case .dark: "#e8eaed"
        }
    }

    var previewColor: Color {
        switch self {
        case .system: Color(nsColor: .windowBackgroundColor)
        case .light: Color(red: 1, green: 1, blue: 1)
        case .sepia: Color(red: 0.98, green: 0.94, blue: 0.85)
        case .dark: Color(red: 0.13, green: 0.13, blue: 0.14)
        }
    }
}

enum ReaderFont: String, CaseIterable, Identifiable {
    case sans, serif

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sans: "Sans-Serif"
        case .serif: "Serif"
        }
    }

    var cssFontFamily: String {
        switch self {
        case .sans: "-apple-system, BlinkMacSystemFont, 'SF Pro Text', sans-serif"
        case .serif: "'New York', 'Iowan Old Style', 'Palatino', Georgia, serif"
        }
    }
}

struct ReaderView: View {
    let tab: Tab
    let article: ReaderArticle
    @AppStorage("readerTheme") private var theme: ReaderTheme = .system
    @AppStorage("readerFont") private var font: ReaderFont = .serif
    @AppStorage("readerFontSize") private var fontSize: Double = 18
    @State private var showOptions = false

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            ReaderContentWebView(
                article: article,
                baseURL: tab.url,
                theme: theme,
                font: font,
                fontSize: fontSize
            )
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var headerBar: some View {
        HStack(spacing: 12) {
            Button("Done") {
                tab.readerArticle = nil
            }
            .keyboardShortcut(.cancelAction)
            .chromeFont(size: 12, weight: .medium)

            if let site = article.siteName {
                Text(site)
                    .chromeFont(size: 11)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Label("\(article.readingTimeMinutes) min read", systemImage: "clock")
                .chromeFont(size: 11)
                .foregroundStyle(.secondary)

            Button {
                showOptions.toggle()
            } label: {
                HStack(spacing: 2) {
                    Text("a")
                        .font(.system(size: 12, weight: .medium, design: font == .serif ? .serif : .default))
                    Text("A")
                        .font(.system(size: 15, weight: .bold, design: font == .serif ? .serif : .default))
                }
                .frame(width: 32, height: 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Reader Appearance")
            .popover(isPresented: $showOptions, arrowEdge: .bottom) {
                optionsPopover
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(height: 38)
    }

    private var optionsPopover: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Reader Appearance")
                .font(.headline)
                .padding(.bottom, 2)

            HStack(spacing: 10) {
                ForEach(ReaderTheme.allCases) { t in
                    Button {
                        theme = t
                    } label: {
                        Circle()
                            .fill(t.previewColor)
                            .frame(width: 28, height: 28)
                            .overlay(Circle().stroke(theme == t ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: theme == t ? 2 : 1))
                    }
                    .buttonStyle(.plain)
                    .help(t.title)
                }
            }

            Divider()

            Picker("Font", selection: $font) {
                ForEach(ReaderFont.allCases) { f in
                    Text(f.title).tag(f)
                }
            }
            .pickerStyle(.segmented)

            HStack(spacing: 12) {
                Button {
                    fontSize = max(14, fontSize - 2)
                } label: {
                    Image(systemName: "textformat.size.smaller")
                        .frame(width: 28, height: 24)
                }
                .disabled(fontSize <= 14)

                Text("\(Int(fontSize)) pt")
                    .font(.caption.monospacedDigit())
                    .frame(width: 44, alignment: .center)

                Button {
                    fontSize = min(32, fontSize + 2)
                } label: {
                    Image(systemName: "textformat.size.larger")
                        .frame(width: 28, height: 24)
                }
                .disabled(fontSize >= 32)
            }
        }
        .padding(16)
        .frame(width: 220)
    }
}

private struct ReaderContentWebView: NSViewRepresentable {
    let article: ReaderArticle
    let baseURL: URL?
    let theme: ReaderTheme
    let font: ReaderFont
    let fontSize: Double

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        WebEnvironment.configureProcessIdentity(config, displayName: "Paddle Reader")
        config.preferences.minimumFontSize = 12
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        updateHTML(in: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        updateHTML(in: webView)
    }

    private func updateHTML(in webView: WKWebView) {
        func escape(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;")
             .replacingOccurrences(of: "<", with: "&lt;")
             .replacingOccurrences(of: ">", with: "&gt;")
             .replacingOccurrences(of: "\"", with: "&quot;")
             .replacingOccurrences(of: "'", with: "&#39;")
        }

        let bg = theme.backgroundColor
        let fg = theme.textColor
        let fontFam = font.cssFontFamily

        let html = """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>\(escape(article.title))</title>
          <style>
            :root {
              color-scheme: \(theme == .dark ? "dark" : (theme == .light || theme == .sepia ? "light" : "light dark"));
            }
            body {
              background-color: \(bg);
              color: \(fg);
              font-family: \(fontFam);
              font-size: \(Int(fontSize))px;
              line-height: 1.68;
              margin: 0;
              padding: 40px 24px 80px 24px;
              text-rendering: optimizeLegibility;
              -webkit-font-smoothing: antialiased;
            }
            .reader-container {
              max-width: 44rem;
              margin: 0 auto;
            }
            h1.article-title {
              font-size: 2.1em;
              line-height: 1.25;
              margin: 0 0 16px 0;
              font-weight: 700;
              letter-spacing: -0.02em;
            }
            .article-meta {
              font-size: 0.9em;
              opacity: 0.75;
              margin-bottom: 32px;
              padding-bottom: 16px;
              border-bottom: 1px solid rgba(128, 128, 128, 0.25);
            }
            .article-meta span + span:before {
              content: " • ";
              padding: 0 4px;
            }
            .article-body {
              overflow-wrap: break-word;
            }
            p {
              margin: 0 0 1.4em 0;
            }
            h2 { font-size: 1.45em; margin: 1.8em 0 0.6em 0; line-height: 1.3; }
            h3 { font-size: 1.2em; margin: 1.6em 0 0.5em 0; line-height: 1.3; }
            blockquote {
              margin: 1.5em 0;
              padding-left: 1.2em;
              border-left: 3px solid rgba(128, 128, 128, 0.4);
              font-style: italic;
              opacity: 0.9;
            }
            img {
              max-width: 100%;
              height: auto;
              border-radius: 6px;
              margin: 1.5em 0;
              display: block;
            }
            figure {
              margin: 1.8em 0;
            }
            figcaption {
              font-size: 0.85em;
              opacity: 0.7;
              margin-top: 6px;
              text-align: center;
            }
            ul, ol {
              margin: 0 0 1.4em 1.5em;
              padding: 0;
            }
            li {
              margin-bottom: 0.5em;
            }
            pre, code {
              font-family: Menlo, Monaco, Consolas, monospace;
              font-size: 0.9em;
              background: rgba(128, 128, 128, 0.12);
              border-radius: 4px;
            }
            code {
              padding: 2px 5px;
            }
            pre {
              padding: 14px;
              overflow-x: auto;
            }
            pre code {
              padding: 0;
              background: none;
            }
            a {
              color: inherit;
              text-decoration: underline;
              text-decoration-color: rgba(128, 128, 128, 0.4);
              text-underline-offset: 3px;
            }
          </style>
        </head>
        <body>
          <div class="reader-container">
            <h1 class="article-title">\(escape(article.title))</h1>
            <div class="article-meta">
              \(article.byline.map { "<span>" + escape($0) + "</span>" } ?? "")
              \(article.publishedTime.map { "<span>" + escape($0) + "</span>" } ?? "")
              \(article.siteName.map { "<span>" + escape($0) + "</span>" } ?? "")
            </div>
            <div class="article-body">
              \(article.contentHTML)
            </div>
          </div>
        </body>
        </html>
        """
        webView.loadHTMLString(html, baseURL: baseURL)
    }
}
