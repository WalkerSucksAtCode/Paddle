import PaddleCore
import SwiftUI

struct MediaControlsButton: View {
    let app: AppModel
    let model: BrowserModel
    @State private var showPopover = false

    private var playingTabs: [Tab] {
        app.allTabs.filter { $0.isAwake && $0.isPlayingAudio && MediaControlsPopover.isListed($0, in: model) }
    }

    var body: some View {
        if !playingTabs.isEmpty {
            Button {
                showPopover.toggle()
            } label: {
                Image(systemName: "speaker.wave.2.fill")
                    .chromeFont(size: 13, weight: .semibold)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Media Playback Controls")
            .accessibilityLabel("Media Playback")
            .accessibilityValue("\(playingTabs.count) tab(s) playing")
            .popover(isPresented: $showPopover, arrowEdge: .bottom) {
                MediaControlsPopover(app: app, currentModel: model)
                    .systemText()
            }
        }
    }
}

struct MediaControlsPopover: View {
    let app: AppModel
    let currentModel: BrowserModel

    /// As the activity popover lists tabs: this window's own, and other windows' of the same profile that aren't
    /// private. A private tab's title, or another profile's, never shows in this window.
    static func isListed(_ tab: Tab, in browser: BrowserModel) -> Bool {
        tab.browser === browser || (!tab.isPrivate && !browser.isPrivate && tab.profileID == browser.profileID)
    }

    private var playingTabs: [Tab] {
        app.allTabs.filter { $0.isAwake && $0.isPlayingAudio && Self.isListed($0, in: currentModel) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Media Playing", systemImage: "play.circle.fill")
                    .font(.headline)
                Spacer()
                Text("\(playingTabs.count)")
                    .font(.caption.monospacedDigit())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.quaternary))
            }
            .padding(.bottom, 4)

            Divider()

            if playingTabs.isEmpty {
                Text("No media currently playing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(playingTabs) { tab in
                    mediaRow(for: tab)
                }
            }
        }
        .padding(14)
        .frame(minWidth: 280, maxWidth: 340)
    }

    private func mediaRow(for tab: Tab) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "music.note")
                .foregroundStyle(.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(tab.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)

                if let host = tab.url?.host() {
                    Text(host)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                jumpTo(tab)
            }

            HStack(spacing: 6) {
                Button {
                    togglePlayback(in: tab)
                } label: {
                    Image(systemName: "pause.fill")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .help("Pause Playback")
                .accessibilityLabel("Pause Playback")

                Button {
                    tab.toggleMute()
                } label: {
                    Image(systemName: tab.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 11))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .help(tab.isMuted ? "Unmute" : "Mute")
                .accessibilityLabel(tab.isMuted ? "Unmute" : "Mute")

                Button {
                    tab.togglePictureInPicture()
                } label: {
                    Image(systemName: "pip.enter")
                        .font(.system(size: 11))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .help("Picture in Picture")
                .accessibilityLabel("Picture in Picture")
            }
        }
        .padding(.vertical, 4)
    }

    private func jumpTo(_ tab: Tab) {
        guard let browser = tab.browser else { return }
        browser.select(tab)
        browser.controller?.window?.makeKeyAndOrderFront(nil)
    }

    private func togglePlayback(in tab: Tab) {
        // Pause-everything, like Safari's tab audio controls: if anything is playing it pauses all of it, and only a
        // page where everything is already paused plays. Per-element toggling would start the paused video next to the
        // playing one the button was aimed at.
        let script = """
        (() => {
            const media = Array.from(document.querySelectorAll('video, audio'));
            const anyPlaying = media.some((m) => !m.paused);
            for (const m of media) {
                if (anyPlaying) { if (!m.paused) { m.pause(); } } else { if (m.paused) { m.play().catch(() => {}); } }
            }
        })()
        """
        // The popover lists background tabs, which may be frozen; scripts raise on a suspended page.
        tab.unfreeze()
        tab.webView?.evaluateJavaScript(script, in: nil, in: .defaultClient) { _ in }
    }
}
