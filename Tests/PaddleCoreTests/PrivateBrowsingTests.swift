import Foundation
@testable import PaddleCore
import Testing

struct PrivateBrowsingTests {
    struct FakeWindow {
        var isPrivate: Bool
        var urls: [String]
    }

    func record(_ window: FakeWindow) -> WindowRecord {
        WindowRecord(tabs: window.urls.map { TabRecord(url: $0, title: "") }, selectedIndex: 0)
    }

    @Test func privateWindowsNeverReachTheSession() {
        let windows = [
            FakeWindow(isPrivate: false, urls: ["https://a.test"]),
            FakeWindow(isPrivate: true, urls: ["https://secret.test"]),
            FakeWindow(isPrivate: false, urls: ["https://b.test"]),
        ]
        let session = SessionRecord.saving(windows, isPrivate: \.isPrivate, record: record)
        #expect(session.windows.map { $0.tabs.map(\.url) } == [["https://a.test"], ["https://b.test"]])
        let json = String(decoding: try! JSONEncoder().encode(session), as: UTF8.self)
        #expect(!json.contains("secret"))
    }

    @Test func onlyPrivateWindowsSaveAnEmptySession() {
        let session = SessionRecord.saving([FakeWindow(isPrivate: true, urls: ["https://x.test"])], isPrivate: \.isPrivate, record: record)
        #expect(session.windows.isEmpty)
    }

    @Test func emptyWindowsAreDropped() {
        let session = SessionRecord.saving([FakeWindow(isPrivate: false, urls: [])], isPrivate: \.isPrivate, record: record)
        #expect(session.windows.isEmpty)
    }

    struct FakeTab {
        var url: String
        var saved = true
    }

    func window(_ tabs: [FakeTab], selected: Int) -> WindowRecord {
        WindowRecord.saving(
            tabs.indices.map { $0 }, selected: { $0 == selected }, isSaved: { tabs[$0].saved },
            record: { TabRecord(url: tabs[$0].url, title: "") }, frame: "f"
        )
    }

    @Test func unsavedTabsAreLeftOutAndSelectionFollows() {
        let tabs = [FakeTab(url: "a"), FakeTab(url: "src", saved: false), FakeTab(url: "b")]
        let afterSource = window(tabs, selected: 2)
        #expect(afterSource.tabs.map(\.url) == ["a", "b"])
        #expect(afterSource.selectedIndex == 1)
        #expect(afterSource.frame == "f")
        // The selected tab isn't saved: the one before it is selected.
        #expect(window(tabs, selected: 1).selectedIndex == 0)
        #expect(window(tabs, selected: 0).selectedIndex == 0)
    }

    @Test func unsavedFirstTabSelectsTheFirstSavedOne() {
        let tabs = [FakeTab(url: "src", saved: false), FakeTab(url: "a"), FakeTab(url: "b")]
        let record = window(tabs, selected: 0)
        #expect(record.tabs.map(\.url) == ["a", "b"])
        #expect(record.selectedIndex == 0)
    }

    @Test func extensionsInPrivateDefaultsOffAndDecodes() throws {
        #expect(PaddleConfig().extensionsInPrivate == false)
        #expect(try PaddleConfig.decode(Data("{}".utf8)).extensionsInPrivate == false)
        #expect(try PaddleConfig.decode(Data(#"{"extensionsInPrivate": true}"#.utf8)).extensionsInPrivate == true)
        #expect(try PaddleConfig.decode(PaddleConfig(extensionsInPrivate: true).encoded()).extensionsInPrivate == true)
    }
}

struct TabAudioTests {
    @Test func mutingTouchesOnlyTheAudioBit() {
        let captureMuted = MediaMutedState.captureDevices
        #expect(MediaMutedState.settingAudio(true, in: 0) == MediaMutedState.audio)
        #expect(MediaMutedState.settingAudio(true, in: captureMuted) == captureMuted | MediaMutedState.audio)
        #expect(MediaMutedState.settingAudio(false, in: captureMuted | MediaMutedState.audio) == captureMuted)
        #expect(MediaMutedState.settingAudio(false, in: 0) == 0)
    }

    @Test func indicator() {
        #expect(AudioIndicator(isPlayingAudio: false, isMuted: false) == .none)
        #expect(AudioIndicator(isPlayingAudio: true, isMuted: false) == .playing)
        #expect(AudioIndicator(isPlayingAudio: true, isMuted: true) == .muted)
        #expect(AudioIndicator(isPlayingAudio: false, isMuted: true) == .muted)
    }

    @Test func soundOrCaptureKeepsATabAwake() {
        #expect(MediaActivity.isBusy(isCapturing: false, isPlayingAudio: true, playbackIsPlaying: false, audioIsObservable: true))
        #expect(MediaActivity.isBusy(isCapturing: true, isPlayingAudio: false, playbackIsPlaying: false, audioIsObservable: true))
        #expect(!MediaActivity.isBusy(isCapturing: false, isPlayingAudio: false, playbackIsPlaying: false, audioIsObservable: true))
    }

    @Test func silentVideoDoesNotKeepATabAwake() {
        // A muted autoplaying preview: media is playing, no sound.
        #expect(!MediaActivity.isBusy(isCapturing: false, isPlayingAudio: false, playbackIsPlaying: true, audioIsObservable: true))
    }

    @Test func withoutTheSoundFlagAnyPlaybackCounts() {
        #expect(MediaActivity.isBusy(isCapturing: false, isPlayingAudio: false, playbackIsPlaying: true, audioIsObservable: false))
        #expect(!MediaActivity.isBusy(isCapturing: false, isPlayingAudio: false, playbackIsPlaying: false, audioIsObservable: false))
    }
}

struct ViewSourceTests {
    @Test func escapesMarkup() {
        #expect(HTMLText.escape(#"<a href="x">Tom & 'Jerry'</a>"#) == "&lt;a href=&quot;x&quot;&gt;Tom &amp; &#39;Jerry&#39;&lt;/a&gt;")
        #expect(HTMLText.escape("plain é 🚣") == "plain é 🚣")
    }

    @Test func pageCannotBreakOutOfThePre() {
        let source = "<html><script>alert(1)</script></pre><img src=x onerror=alert(2)></html>"
        let page = ViewSource.page(source: source, url: URL(string: "https://example.com/a?b=1&c=2"))
        #expect(!page.contains("<script>"))
        #expect(!page.contains("<img"))
        #expect(page.components(separatedBy: "</pre>").count == 2)
        #expect(page.contains("&lt;script&gt;alert(1)&lt;/script&gt;"))
        #expect(page.contains("https://example.com/a?b=1&amp;c=2"))
        #expect(page.contains("default-src 'none'"))
        #expect(page.contains("<title>Source of example.com</title>"))
        #expect(page.contains("Current DOM"))
    }

    @Test func titles() {
        #expect(ViewSource.title(for: URL(string: "https://www.example.com/x")) == "Source of www.example.com")
        #expect(ViewSource.title(for: URL(string: "file:///tmp/a.html")) == "Source of file:///tmp/a.html")
        #expect(ViewSource.title(for: nil) == "Source")
    }
}
