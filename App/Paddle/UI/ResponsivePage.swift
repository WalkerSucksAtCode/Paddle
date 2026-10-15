import AppKit
import PaddleCore
import SwiftUI

/// Responsive Design Mode for one tab: a bar of device controls over a plain backdrop with the page at the device's size.
struct ResponsivePage: View {
    let tab: Tab
    private static let barHeight: CGFloat = 35
    /// Backdrop around the device.
    private static let inset: CGFloat = 16

    var body: some View {
        if let state = tab.responsive {
            GeometryReader { geometry in
                let size = state.size
                let area = CGSize(width: geometry.size.width, height: geometry.size.height - Self.barHeight)
                // Never scaled: a scale effect only transforms the layer (AppKit hit-tests the untransformed frame),
                // and WebKit's view scale and page zoom change devicePixelRatio and fixed positioning. A device bigger
                // than the window is shown at 1:1 and the backdrop scrolls.
                let fits = CGFloat(size.width) + 2 * Self.inset <= area.width && CGFloat(size.height) + 2 * Self.inset <= area.height
                VStack(spacing: 0) {
                    ResponsiveBar(tab: tab, state: state, fits: fits)
                        .frame(height: Self.barHeight - 1)
                    Divider()
                    ScrollView([.horizontal, .vertical]) {
                        WebContainer(tab: tab, generation: tab.generation)
                            .frame(width: CGFloat(size.width), height: CGFloat(size.height))
                            .padding(1)
                            .background(Color(nsColor: .separatorColor))
                            .padding(Self.inset)
                            .frame(minWidth: area.width, minHeight: area.height)
                    }
                    .background(Color(nsColor: .underPageBackgroundColor))
                }
            }
        }
    }
}

private struct ResponsiveBar: View {
    let tab: Tab
    let state: ResponsiveState
    let fits: Bool

    var body: some View {
        HStack(spacing: 10) {
            Picker("Device", selection: Binding(get: { state.deviceID }, set: { tab.setResponsiveDevice($0) })) {
                ForEach(ResponsiveDevice.presets) { Text($0.label).tag($0.id) }
            }
            .fixedSize()
            .accessibilityLabel("Device")
            Button {
                tab.responsive?.rotated.toggle()
            } label: {
                Label("Rotate", systemImage: "rotate.right")
            }
            .accessibilityLabel("Rotate")
            .help("Swap width and height")
            Picker("User agent", selection: Binding(get: { state.userAgent }, set: { tab.setResponsiveUserAgent($0) })) {
                ForEach(ResponsiveUserAgent.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .fixedSize()
            .accessibilityLabel("User agent")
            Text(verbatim: "\(state.size.width) × \(state.size.height)")
                .chromeFont(size: 11, monospacedDigit: true)
                .foregroundStyle(.secondary)
            if !fits {
                Text("Larger than the window: scroll to see all of it")
                    .chromeFont(size: 11)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Close") { tab.toggleResponsive() }
                .accessibilityLabel("Close Responsive Design Mode")
        }
        .chromeFont(size: 12)
        .padding(.horizontal, 12)
        .chromeSurface(.toolbar)
    }
}
