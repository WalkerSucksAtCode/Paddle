import SwiftUI

/// One of Paddle's own toolbar glyphs from Assets.xcassets (surf-*). They are drawn in their own colors, so an
/// inactive state is shown greyed and faded rather than tinted. Decorative: the button around it gives the label.
struct Glyph: View {
    let name: String
    var size: CGFloat = 14
    var active = true

    var body: some View {
        Image(decorative: name)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .saturation(active ? 1 : 0)
            .opacity(active ? 1 : 0.55)
    }
}
