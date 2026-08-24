import SwiftUI

/// Explicit colours rather than the dynamic system ones. The app is pinned to a dark
/// appearance around a black canvas, so letting labels follow the user's system theme is
/// what leaves them unreadable.
enum Palette {
    static let panel = Color(red: 0.09, green: 0.09, blue: 0.11)
    static let card = Color(red: 0.14, green: 0.14, blue: 0.17)
    static let label = Color(white: 0.94)
    static let secondary = Color(white: 0.62)
    static let warning = Color(red: 1.0, green: 0.68, blue: 0.30)
    static let canvas = Color.black
}

/// Card container drawn with explicit colours rather than GroupBox's system styling.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8).fill(Palette.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8).strokeBorder(Color(white: 0.24), lineWidth: 1)
            )
    }
}

extension View {
    /// Background and label colour for every panel, applied once at the root.
    func panelSurface() -> some View {
        self
            .foregroundStyle(Palette.label)
            .background(Palette.panel)
    }
}
