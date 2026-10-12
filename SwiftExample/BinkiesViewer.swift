import SwiftUI
import WebKit

// Page that runs the Binkies integration (the 3D viewer) full size in its #target element.
// The app only loads it once and then drives it through window.binkies.setSettings.
private let viewerURL = URL(string: "https://mobile-app.binkies3d.com/")!

// Console tag for the bridge messages
private let logTag = "[Binkies]"

/// The 3D viewer page in a WKWebView, talking to it over the BinkiesNative bridge.
///
/// - `product` is the Binkies content id to show. Changing it switches the model without reloading the page.
/// - `visible` is bound to whether the viewer takes up space: the view sets it to `true` once the page
///   sends "show" (the product's 3D model has loaded), and to `false` on "hide".
///
/// The caller is expected to collapse this view's height (not remove it / give it zero size) while
/// `visible` is `false`: a WKWebView that isn't laid out at a real size can stall its page, so the next
/// model would never finish loading and "show" would never arrive. See `ViewerContainer` in ContentView.swift.
struct BinkiesViewer: UIViewRepresentable {
    let product: String
    @Binding var visible: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(product: product, onVisibilityChange: { visible = $0 })
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // Exposes window.webkit.messageHandlers.BinkiesNative.postMessage({...}) to the page. The page
        // can post as soon as it starts (e.g. "hide" without WebGL2, or errors), so the handler is
        // registered before load().
        configuration.userContentController.add(context.coordinator, name: "BinkiesNative")
        // Sets window.settings before any script of the viewer page runs, the page applies it when it starts.
        let script = WKUserScript(
            source: "window.settings = \(Self.initialSettingsJSON(product: product));",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        configuration.userContentController.addUserScript(script)

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        webView.load(URLRequest(url: viewerURL))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // Only the changed field is sent, the page deep-merges it into its current settings.
        // Before the page has committed, didCommit sends the product instead.
        context.coordinator.setProduct(product)
    }

    /// The full settings, the page starts with them. The page rejects unknown keys and invalid values:
    /// - product: Binkies content id
    /// - gallery.thumbnails.placement: "bottom", "left" or "right"
    /// - gallery.thumbnails.selectedColor: border of the selected thumbnail, any CSS color
    fileprivate static func initialSettingsJSON(product: String) -> String {
        """
        {"product": "\(product)", "gallery": {"thumbnails": {"placement": "bottom", "selectedColor": "#262626"}}}
        """
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        private var product: String
        private let onVisibilityChange: (Bool) -> Void
        private var pageCommitted = false
        weak var webView: WKWebView?

        init(product: String, onVisibilityChange: @escaping (Bool) -> Void) {
            self.product = product
            self.onVisibilityChange = onVisibilityChange
        }

        func setProduct(_ product: String) {
            guard self.product != product else { return }
            self.product = product
            // Before the bridge is loaded, webView(_:didCommit:) sends the product instead.
            if pageCommitted {
                send(json: #"{"product": "\#(product)"}"#)
            }
        }

        // Fires once the page's first frame is visible, the same moment window.binkies becomes
        // available (the page sets it up in a blocking script in its <head>).
        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            pageCommitted = true
            // The product may have changed while the page was loading; send it once now.
            send(json: #"{"product": "\#(product)"}"#)
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
            case "show":
                onVisibilityChange(true)
            case "hide":
                onVisibilityChange(false)
            case "error":
                // Anything the page logged as an error, e.g. invalid settings. Forward it to your crash reporting if you like.
                let message = json["message"] as? String ?? ""
                let stack = json["stack"] as? String ?? ""
                print("\(logTag) \(errorText(message: message, stack: stack))")
            default:
                break
            }
        }

        // Sends (partial) settings to the page, which deep-merges them into its current settings.
        // evaluateJavaScript doesn't report JS errors on this delegate, so they are logged with
        // console.error, which the page sends back as an "error" message.
        private func send(json: String) {
            webView?.evaluateJavaScript("try { window.binkies.setSettings(\(json)) } catch (error) { console.error(error) }")
        }
    }
}

// A JS stack usually starts with the message itself, so it's only added when it doesn't
private func errorText(message: String, stack: String) -> String {
    if stack.isEmpty { return message }
    if stack.hasPrefix(message) { return stack }
    return "\(message)\n\(stack)"
}
