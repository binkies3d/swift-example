import SwiftUI
import UIKit
import WebKit

// Page that runs the Binkies integration (the 3D viewer) full size in its #target element.
// The app only loads it once and then drives it through window.binkies.setSettings.
private let viewerURL = URL(string: "https://mobile-app.binkies3d.com/")!

// Console tag for the bridge messages
private let logTag = "[Binkies]"

/// Where the thumbnail strip is placed (page setting gallery.thumbnails.placement).
enum ThumbnailsPlacement: String {
    case bottom, left, right
}

/// The settings sent to the page. The page rejects unknown keys and invalid values; the types here
/// make sure the app can't send an invalid placement or color.
///
/// To use a new setting of the page, add a property with a default value and put it into `toJSON()`.
struct BinkiesSettings: Equatable {
    /// Binkies content id of the product to show (page setting product).
    var product: String
    /// Page setting gallery.thumbnails.placement.
    var thumbnailsPlacement: ThumbnailsPlacement = .bottom
    /// Border color of the selected thumbnail (page setting gallery.thumbnails.selectedColor).
    var thumbnailsSelectedColor: Color = Color(red: 0x26 / 255, green: 0x26 / 255, blue: 0x26 / 255)

    /// All settings as the page's JSON object.
    fileprivate func toJSON() -> String {
        let object: [String: Any] = [
            "product": product,
            "gallery": [
                "thumbnails": [
                    "placement": thumbnailsPlacement.rawValue,
                    "selectedColor": cssColor(thumbnailsSelectedColor),
                ],
            ],
        ]
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}

/// The 3D viewer page in a WKWebView, talking to it over the BinkiesNative bridge.
///
/// - `settings` is what the page shows. Changing it (e.g. another product) updates the viewer without
///   reloading the page.
/// - `visible` expands or collapses the viewer. Set it from `onVisibilityChange`: `true` once the page
///   sends "show" (the product's 3D model has loaded), `false` on "hide".
/// - `onError` gets every error the page logs, e.g. to forward it to your crash reporting.
///
/// The viewer takes the full width and collapses by animating the height of a clipping frame around the
/// WKWebView. The WKWebView itself always keeps its full size: one laid out at zero height stalls its
/// page, so the next model would never finish loading and "show" would never arrive.
struct BinkiesViewer: View {
    let settings: BinkiesSettings
    let visible: Bool
    let onVisibilityChange: (Bool) -> Void
    var onError: (String) -> Void = { _ in }

    @State private var width: CGFloat = 0

    // 5:6 (width:height), which fits the model with the thumbnails below it
    private var viewerHeight: CGFloat { width * 1.2 }

    var body: some View {
        // The width is measured on the clipping frame itself: it always takes the full width, whatever its height.
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: visible ? viewerHeight : 0)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .overlay(alignment: .top) {
                BinkiesWebView(settings: settings, onVisibilityChange: onVisibilityChange, onError: onError)
                    .frame(width: width, height: viewerHeight)
            }
            .clipped()
            .animation(.default, value: visible)
    }
}

/// The WKWebView and the bridge, without any layout.
private struct BinkiesWebView: UIViewRepresentable {
    let settings: BinkiesSettings
    let onVisibilityChange: (Bool) -> Void
    let onError: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(settings: settings)
    }

    func makeUIView(context: Context) -> WKWebView {
        context.coordinator.onVisibilityChange = onVisibilityChange
        context.coordinator.onError = onError

        let configuration = WKWebViewConfiguration()
        // Exposes window.webkit.messageHandlers.BinkiesNative.postMessage({...}) to the page. The page
        // posts as soon as it starts (it asks for its settings right away), so the handler is
        // registered before load().
        configuration.userContentController.add(context.coordinator, name: "BinkiesNative")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        context.coordinator.webView = webView
        webView.load(URLRequest(url: viewerURL))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // The closures capture the caller's current state, so they are refreshed on every update.
        context.coordinator.onVisibilityChange = onVisibilityChange
        context.coordinator.onError = onError
        context.coordinator.setSettings(settings)
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        private var settings: BinkiesSettings
        var onVisibilityChange: (Bool) -> Void = { _ in }
        var onError: (String) -> Void = { _ in }
        weak var webView: WKWebView?

        init(settings: BinkiesSettings) {
            self.settings = settings
        }

        func setSettings(_ settings: BinkiesSettings) {
            guard self.settings != settings else { return }
            self.settings = settings
            // Until the page is ready this does nothing, the page then asks for the current settings.
            sendSettings()
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            let json: [String: Any]?
            if let dictionary = message.body as? [String: Any] {
                json = dictionary
            } else if let string = message.body as? String, let data = string.data(using: .utf8) {
                json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            } else {
                json = nil
            }
            guard let json else { return }

            switch json["type"] as? String {
            case "setSettings":
                // The page is ready for its settings, once per page load (also after a reload)
                sendSettings()
            case "show":
                onVisibilityChange(true)
            case "hide":
                onVisibilityChange(false)
            case "error":
                // Anything the page logged as an error, e.g. invalid settings
                let message = json["message"] as? String ?? ""
                let stack = json["stack"] as? String ?? ""
                let text = errorText(message: message, stack: stack)
                print("\(logTag) \(text)")
                onError(text)
            default:
                break
            }
        }

        // Sends all settings to the page. Before the page is ready window.binkies doesn't exist and
        // this does nothing. evaluateJavaScript doesn't report JS errors on this delegate, so they are
        // logged with console.error, which the page sends back as an "error" message.
        private func sendSettings() {
            let json = settings.toJSON()
            webView?.evaluateJavaScript("try { window.binkies?.setSettings(\(json)) } catch (error) { console.error(error) }")
        }
    }
}

// A JS stack usually starts with the message itself, so it's only added when it doesn't
private func errorText(message: String, stack: String) -> String {
    if stack.isEmpty { return message }
    if stack.hasPrefix(message) { return stack }
    return "\(message)\n\(stack)"
}

// The color as a CSS hex color, #rrggbb or #rrggbbaa when it isn't opaque
private func cssColor(_ color: Color) -> String {
    var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
    UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
    let components = alpha < 1 ? [red, green, blue, alpha] : [red, green, blue]
    return "#" + components.map { String(format: "%02x", Int((min(max($0, 0), 1) * 255).rounded())) }.joined()
}
