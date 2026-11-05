import Foundation
@testable import PaddleCore
import Testing
import WebKit

@MainActor
struct ScrollRestoreScriptTests {
    private func page(_ html: String) -> (webView: WKWebView, folder: URL) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.addUserScript(WKUserScript(
            source: ScrollRestoreScript.source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page
        ))
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 240), configuration: configuration)
        // A file, not loadHTMLString: a string load gets no back/forward item, so pushState adds no entry and Back
        // has nothing to go to.
        let folder = FileManager.default.temporaryDirectory.appending(path: "paddle-scroll-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "timeline.html")
        try? Data(html.utf8).write(to: file)
        webView.loadFileURL(file, allowingReadAccessTo: folder)
        return (webView, folder)
    }

    private func columnTop(_ webView: WKWebView) async -> Double? {
        let value = try? await webView.evaluateJavaScript("document.getElementById('col').scrollTop")
        if let number = value as? Double { return number }
        if let number = value as? Int { return Double(number) }
        return nil
    }

    /// A column the site resets to the top on the way into a post comes back to where it was.
    @Test func columnComesBackAfterTheSiteResetsIt() async {
        let (webView, folder) = page("""
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
            window.__reset = true;
          }, 80);
          addEventListener('popstate', () => { window.__popped = true; });
        </script>
        """)
        // Back as the user takes it (the browser's Back, not the page's history.back()), once the site has reset the
        // column; a poll before that would pass on the 800 the page set first. Under load the page can take seconds.
        func flag(_ name: String) async -> Bool {
            (try? await webView.evaluateJavaScript("window.\(name) === true")) as? Bool ?? false
        }
        let loadDeadline = ContinuousClock.now + .seconds(30)
        var reset = false
        while !reset, ContinuousClock.now < loadDeadline {
            reset = await flag("__reset")
            if !reset { try? await Task.sleep(for: .milliseconds(50)) }
        }
        #expect(reset, "the page never reset its column")
        #expect(await columnTop(webView) == 0)
        webView.goBack()
        var popped = false
        while reset, !popped, ContinuousClock.now < loadDeadline {
            popped = await flag("__popped")
            if !popped { try? await Task.sleep(for: .milliseconds(50)) }
        }
        #expect(popped, "Back never fired popstate")
        let deadline = ContinuousClock.now + .seconds(2)
        var top: Double?
        while popped, ContinuousClock.now < deadline {
            top = await columnTop(webView)
            if let top, top >= 700 { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        #expect(top ?? 0 >= 700)
        _ = webView
        try? FileManager.default.removeItem(at: folder)
    }

    /// Assigning `pageZoom` during the restore window must not cancel column restore (same-host Back after WebKit reflow).
    @Test func columnRestoreSurvivesPageZoomDuringRestoreWindow() async {
        let (webView, folder) = page("""
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
            window.__reset = true;
          }, 80);
          addEventListener('popstate', () => { window.__popped = true; });
        </script>
        """)
        func flag(_ name: String) async -> Bool {
            (try? await webView.evaluateJavaScript("window.\(name) === true")) as? Bool ?? false
        }
        let loadDeadline = ContinuousClock.now + .seconds(30)
        var reset = false
        while !reset, ContinuousClock.now < loadDeadline {
            reset = await flag("__reset")
            if !reset { try? await Task.sleep(for: .milliseconds(50)) }
        }
        #expect(reset)
        webView.goBack()
        var popped = false
        while !popped, ContinuousClock.now < loadDeadline {
            popped = await flag("__popped")
            if !popped { try? await Task.sleep(for: .milliseconds(50)) }
        }
        #expect(popped)
        webView.pageZoom = 1.25
        let deadline = ContinuousClock.now + .seconds(2)
        var top: Double?
        while ContinuousClock.now < deadline {
            top = await columnTop(webView)
            if let top, top >= 700 { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        #expect(top ?? 0 >= 700)
        try? FileManager.default.removeItem(at: folder)
    }

    /// X-class sites reset the column hundreds of milliseconds after `popstate`; restore must keep fighting until then.
    @Test func columnComesBackAfterLateSiteResetOnBack() async {
        let (webView, folder) = page("""
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
            window.__reset = true;
          }, 80);
          addEventListener('popstate', () => {
            window.__popped = true;
            setTimeout(() => { col.scrollTop = 0; window.__lateReset = true; }, 900);
          });
        </script>
        """)
        func flag(_ name: String) async -> Bool {
            (try? await webView.evaluateJavaScript("window.\(name) === true")) as? Bool ?? false
        }
        let loadDeadline = ContinuousClock.now + .seconds(30)
        var reset = false
        while !reset, ContinuousClock.now < loadDeadline {
            reset = await flag("__reset")
            if !reset { try? await Task.sleep(for: .milliseconds(50)) }
        }
        #expect(reset)
        webView.goBack()
        var lateReset = false
        while !lateReset, ContinuousClock.now < loadDeadline {
            lateReset = await flag("__lateReset")
            if !lateReset { try? await Task.sleep(for: .milliseconds(50)) }
        }
        #expect(lateReset, "site never reset the column after Back")
        let deadline = ContinuousClock.now + .seconds(3)
        var top: Double?
        while ContinuousClock.now < deadline {
            top = await columnTop(webView)
            if let top, top >= 700 { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        #expect(top ?? 0 >= 700)
        try? FileManager.default.removeItem(at: folder)
    }
}
