import Foundation
@testable import PaddleCore
import Testing
import WebKit

@MainActor
struct ScrollRestoreScriptTests {
    private func page(_ html: String) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.addUserScript(WKUserScript(
            source: ScrollRestoreScript.source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page
        ))
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 240), configuration: configuration)
        webView.loadHTMLString(html, baseURL: URL(string: "https://example.com/timeline"))
        return webView
    }

    private func columnTop(_ webView: WKWebView) async -> Double? {
        let value = try? await webView.evaluateJavaScript("document.getElementById('col').scrollTop")
        if let number = value as? Double { return number }
        if let number = value as? Int { return Double(number) }
        return nil
    }

    /// A column the site resets to the top on the way into a post comes back to where it was.
    @Test func columnComesBackAfterTheSiteResetsIt() async {
        let webView = page("""
        <style>
          html, body { margin: 0; height: 100%; overflow: hidden; }
          #col { height: 240px; overflow: auto; }
          #inner { height: 4000px; }
        </style>
        <div id="col" data-testid="primaryColumn"><div id="inner"></div></div>
        <script>
          const col = document.getElementById('col');
          col.scrollTop = 800;
          setTimeout(() => {
            history.pushState({}, '', '#post');
            col.scrollTop = 0;
            setTimeout(() => history.back(), 40);
          }, 80);
        </script>
        """)
        let deadline = ContinuousClock.now + .seconds(5)
        var top: Double?
        while ContinuousClock.now < deadline {
            top = await columnTop(webView)
            if let top, top >= 700 { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        #expect(top ?? 0 >= 700)
        _ = webView
    }
}
