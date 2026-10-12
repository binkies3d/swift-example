import SwiftUI

/// The product variants the app offers. `productId` is the Binkies content id that is sent to
/// the viewer as the "product" setting, the rest is only used by the app's own UI.
enum ProductColor: String, CaseIterable, Identifiable {
    case cream, mint, pink

    var id: String { rawValue }

    var label: String {
        switch self {
        case .cream: return "Cream"
        case .mint: return "Mint"
        case .pink: return "Pink"
        }
    }

    var swatch: Color {
        switch self {
        case .cream: return Color(red: 0xF1 / 255, green: 0xE9 / 255, blue: 0xD6 / 255)
        case .mint: return Color(red: 0xBF / 255, green: 0xE3 / 255, blue: 0xD0 / 255)
        // No 3D model exists for this content id, so the page answers with "hide"
        case .pink: return Color(red: 0xF4 / 255, green: 0xC6 / 255, blue: 0xD2 / 255)
        }
    }

    var productId: String { "samsung-galaxy-z-flip8-\(rawValue)" }
}

/// Example product page: the 3D viewer on top, the color selector below it.
/// Selecting a color only changes `BinkiesViewer`'s product, the WKWebView stays loaded.
struct ContentView: View {
    @State private var selected: ProductColor = .cream
    // nil until the page sends its first "show" or "hide"
    @State private var visible: Bool?

    var body: some View {
        // GeometryReader as the root view is the straightforward way to read the window's width in
        // SwiftUI; ViewerContainer needs it up front, it's not something to derive from a child.
        GeometryReader { proxy in
            VStack(alignment: .leading, spacing: 0) {
                // Stays collapsed until the page reports that the selected product has a 3D model
                ViewerContainer(product: selected.productId, visible: $visible, width: proxy.size.width)

                Text("Color: \(selected.label)\(visible == false ? " (no 3D)" : "")")
                    .font(.title3.weight(.medium))
                    .padding(.horizontal, 16)
                    .padding(.top, 16)

                ColorSelector(selected: $selected)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)

                Spacer(minLength: 0)
            }
        }
    }
}

/// Row of round color swatches, the selected one gets a border.
private struct ColorSelector: View {
    @Binding var selected: ProductColor

    var body: some View {
        HStack(spacing: 16) {
            ForEach(ProductColor.allCases) { color in
                Circle()
                    .fill(color.swatch)
                    .frame(width: 36, height: 36)
                    .padding(4)
                    .overlay(Circle().stroke(color == selected ? Color.primary : .clear, lineWidth: 2))
                    .contentShape(Circle())
                    .onTapGesture { selected = color }
            }
        }
    }
}

/// Animates the viewer's height between 0 and a 5:6 (width:height) aspect ratio, full width, which
/// fits the model with the thumbnails below it, same as the Kotlin example.
///
/// The BinkiesViewer itself always keeps the full `viewerHeight`, pinned to the top; only this
/// container's height animates and clips it, so the WKWebView is never resized while it opens or closes.
private struct ViewerContainer: View {
    let product: String
    @Binding var visible: Bool?
    let width: CGFloat

    private var viewerHeight: CGFloat { width * 1.2 }

    var body: some View {
        BinkiesViewer(product: product, visible: Binding(get: { visible == true }, set: { visible = $0 }))
            .frame(width: width, height: viewerHeight, alignment: .top)
            .frame(height: visible == true ? viewerHeight : 0, alignment: .top)
            .clipped()
            .animation(.default, value: visible == true)
    }
}

#Preview {
    ContentView()
}
