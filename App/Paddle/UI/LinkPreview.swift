import AppKit
import SwiftUI

/// The link preview over the content area: a darkened backdrop and a card with a small header over the previewed
/// page. The page's web view is the preview Tab's own container; opening it as a tab hands that container to the
/// tab's WebContainer, so the card keeps no reference to it once `model.preview` is nil.
struct LinkPreviewOverlay: View {
    let model: BrowserModel
    @Environment(\.chromeReducesMotion) private var reducesMotion

    var body: some View {
        ZStack {
            if let preview = model.preview {
                LinkPreviewCard(model: model, preview: preview)
                    .id(preview.id)
                    .transition(reducesMotion ? .identity : .opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .animation(reducesMotion ? nil : .easeOut(duration: 0.15), value: model.preview?.id)
    }
}

private struct LinkPreviewCard: View {
    let model: BrowserModel
    let preview: Tab
    @Environment(\.chromeTheme) private var theme

    private let headerHeight: CGFloat = 32

    var body: some View {
        GeometryReader { geometry in
            let insetX = max(16, geometry.size.width * 0.05)
            let insetY = max(16, geometry.size.height * 0.05)
            ZStack {
                // Darkens the page (brightness, not hue); a click on it closes the preview.
                Color.black.opacity(0.4)
                    .contentShape(Rectangle())
                    .onTapGesture { model.closePreview() }
                    .accessibilityHidden(true)
                VStack(spacing: 0) {
                    header
                    WebContainer(tab: preview, generation: preview.generation, takesKeyboard: true, forPreview: true)
                        .overlay(alignment: .bottomLeading) { LinkStatusBubble(tab: preview) }
                }
                .background(theme?.toolbar ?? Color(nsColor: .windowBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                // A thin dark edge so the card's outline measures against a white page too.
                .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Color.black.opacity(0.25), lineWidth: 1) }
                .shadow(color: .black.opacity(0.35), radius: 20)
                .padding(.horizontal, insetX)
                .padding(.vertical, insetY)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Link preview")
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            FaviconView(url: preview.url, fallback: "globe")
            // The host first and always: the address field shows the tab underneath, so this is the only place the
            // previewed page's origin shows, and a page can title itself anything. The title truncates first.
            Text(hostText)
                .chromeFont(size: 12, weight: .medium)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
            Text(preview.title)
                .chromeFont(size: 12)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            button("arrow.up.right.square", help: "Open as Tab") { model.openPreviewAsTab(split: false) }
            if model.canSplitPreview {
                button("rectangle.split.2x1", help: "Open in Mosaic") { model.openPreviewAsTab(split: true) }
            }
            button("link", help: "Copy Link", enabled: preview.url != nil) {
                guard let url = preview.url else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
            }
            button("xmark", help: "Close") { model.closePreview() }
        }
        .padding(.horizontal, 10)
        .frame(height: headerHeight)
        .chromeSurface(.toolbar)
        .overlay(alignment: .bottomLeading) { progressLine }
    }

    private var hostText: String { preview.url?.host() ?? preview.url?.absoluteString ?? "" }

    @ViewBuilder
    private var progressLine: some View {
        if preview.isLoading {
            GeometryReader { geometry in
                Rectangle()
                    .fill(theme?.accent ?? Color.accentColor)
                    .frame(width: geometry.size.width * max(0.05, preview.progress), height: 2)
            }
            .frame(height: 2)
        }
    }

    private func button(_ symbol: String, help: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .chromeFont(size: 12, weight: .medium)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(!enabled)
        .help(help)
        .accessibilityLabel(help)
    }
}
