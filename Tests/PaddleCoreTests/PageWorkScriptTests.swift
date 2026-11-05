import Foundation
@testable import PaddleCore
import Testing
import WebKit

@MainActor
private final class Recorder: NSObject, WKScriptMessageHandler {
    var messages: [[String: Any]] = []
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if let body = message.body as? [String: Any] { messages.append(body) }
    }
}

@MainActor
struct PageWorkScriptTests {
    private func page(_ html: String) -> (WKWebView, Recorder) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let recorder = Recorder()
        configuration.userContentController.add(recorder, contentWorld: .page, name: PageWorkScript.handlerName)
        configuration.userContentController.addUserScript(WKUserScript(
            source: PageWorkScript.source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page
        ))
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.loadHTMLString(html, baseURL: URL(string: "https://example.com/"))
        return (webView, recorder)
    }

    private func wait(_ recorder: Recorder, until done: ([[String: Any]]) -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline, !done(recorder.messages) {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    @Test func beforeunloadListenerAndHandlerReportUnsavedChanges() async {
        let (webView, recorder) = page("""
        <input id="field">
        <script>
          const f = () => {};
          addEventListener('beforeunload', f);
          setTimeout(() => { document.getElementById('field').focus(); document.execCommand('insertText', false, 'x'); }, 50);
          setTimeout(() => removeEventListener('beforeunload', f), 100);
          setTimeout(() => { window.onbeforeunload = () => 'unsaved'; }, 150);
        </script>
        """)
        await wait(recorder) { $0.count >= 3 }
        #expect(recorder.messages.map { $0["guardsUnload"] as? Bool } == [true, false, true])
        _ = webView
    }

    @Test func largeUploadCountsUntilItEndsAndSmallPostsDont() async {
        let (webView, recorder) = page("""
        <script>
          fetch('https://example.invalid/small', { method: 'POST', body: 'x'.repeat(100) }).catch(() => {});
          fetch('https://example.invalid/big', { method: 'POST', body: new Blob(['x'.repeat(\(PageWorkScript.uploadThreshold))]) })
            .catch(() => {});
        </script>
        """)
        await wait(recorder) { $0.count >= 2 }
        #expect(recorder.messages.map { $0["uploading"] as? Bool } == [true, false])
        _ = webView
    }

    @Test func xhrUploadCounts() async {
        let (webView, recorder) = page("""
        <script>
          const x = new XMLHttpRequest();
          x.open('POST', 'https://example.invalid/upload');
          x.send(new Uint8Array(\(PageWorkScript.uploadThreshold)));
        </script>
        """)
        await wait(recorder) { $0.count >= 2 }
        #expect(recorder.messages.map { $0["uploading"] as? Bool } == [true, false])
        _ = webView
    }
}
