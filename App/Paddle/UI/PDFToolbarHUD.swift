import AppKit
import PaddleCore
import SwiftUI
import WebKit

/// A floating HUD toolbar presented over a PDF document in Paddle.
/// Provides controls for opening in macOS Preview, zooming, saving/exporting, and printing.
struct PDFToolbarHUD: View {
    let tab: Tab
    let model: BrowserModel
    @Environment(\.chromeTheme) private var theme
    @State private var isVisible = true

    var body: some View {
        if isVisible {
            HStack(spacing: 8) {
                // PDF badge
                Text("PDF")
                    .chromeFont(size: 10, weight: .bold)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4).fill(theme?.accent?.opacity(0.2) ?? Color.accentColor.opacity(0.2)))
                    .foregroundStyle(theme?.accent ?? Color.accentColor)

                // Open in Preview
                Button {
                    model.controller?.paddleOpenInPreview(nil)
                } label: {
                    Label("Preview", systemImage: "arrow.up.right.square")
                        .chromeFont(size: 11, weight: .medium)
                }
                .buttonStyle(.borderless)
                .help("Open in Preview.app")
                .accessibilityLabel("Open in Preview")

                Divider()
                    .frame(height: 14)

                // Zoom Out
                Button {
                    model.controller?.paddleZoomOut(nil)
                } label: {
                    Image(systemName: "minus.magnifyingglass")
                        .chromeFont(size: 12)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.borderless)
                .help("Zoom Out (⌘-)")
                .accessibilityLabel("Zoom Out")

                // Actual Size (100%)
                Button {
                    model.controller?.paddleActualSize(nil)
                } label: {
                    Text("\(Int(round((tab.webView?.pageZoom ?? 1.0) * 100)))%")
                        .chromeFont(size: 11, weight: .medium)
                        .monospacedDigit()
                }
                .buttonStyle(.borderless)
                .help("Actual Size (⌘0)")
                .accessibilityLabel("Actual Size")

                // Zoom In
                Button {
                    model.controller?.paddleZoomIn(nil)
                } label: {
                    Image(systemName: "plus.magnifyingglass")
                        .chromeFont(size: 12)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.borderless)
                .help("Zoom In (⌘+)")
                .accessibilityLabel("Zoom In")

                Divider()
                    .frame(height: 14)

                // Save PDF
                Button {
                    model.controller?.paddleExportPDF(nil)
                } label: {
                    Image(systemName: "square.and.arrow.down")
                        .chromeFont(size: 12)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.borderless)
                .help("Save PDF…")
                .accessibilityLabel("Save PDF")

                // Print
                Button {
                    model.controller?.paddlePrint(nil)
                } label: {
                    Image(systemName: "printer")
                        .chromeFont(size: 12)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.borderless)
                .help("Print… (⌘P)")
                .accessibilityLabel("Print")

                Divider()
                    .frame(height: 14)

                // Dismiss
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isVisible = false
                    }
                } label: {
                    Image(systemName: "xmark")
                        .chromeFont(size: 10, weight: .bold)
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.borderless)
                .help("Dismiss Toolbar")
                .accessibilityLabel("Dismiss Toolbar")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .chromeMaterial(in: Capsule())
            .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }
}
