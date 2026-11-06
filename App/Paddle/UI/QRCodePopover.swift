import AppKit
import CoreImage.CIFilterBuiltins
import PaddleCore
import SwiftUI

struct QRCodePopover: View {
    let url: URL
    let title: String
    @Environment(\.chromeTheme) private var theme
    @State private var copied = false
    @State private var image: NSImage?

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "qrcode")
                    .foregroundStyle(theme?.accent ?? Color.accentColor)
                Text("Page QR Code")
                    .chromeFont(size: 13, weight: .semibold)
                Spacer()
            }

            // Generated once per presented page, not per render (the copied toggle and theme changes re-rendered
            // the CIFilter each time before).
            if let image {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 180, height: 180)
                    .padding(8)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .shadow(color: .black.opacity(0.1), radius: 4)
            } else {
                Text("Could not generate QR code")
                    .chromeFont(size: 11)
                    .foregroundStyle(.secondary)
            }

            Text("Scan with your mobile camera to open this page.")
                .chromeFont(size: 11)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                } label: {
                    Label(copied ? "Copied!" : "Copy Link", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(14)
        .frame(width: 240)
        .task(id: url.absoluteString) { image = generateQRCode(from: url.absoluteString) }
    }

    private func generateQRCode(from string: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        guard let data = string.data(using: .utf8) else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }

        let rep = NSCIImageRep(ciImage: output)
        let nsImage = NSImage(size: NSSize(width: 180, height: 180))
        nsImage.addRepresentation(rep)
        return nsImage
    }
}
