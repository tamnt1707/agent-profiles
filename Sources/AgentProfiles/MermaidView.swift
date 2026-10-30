import SwiftUI
import WebKit

/// Draws a Mermaid diagram with the Mermaid script that is bundled with the app,
/// so it works without a network. The page is the app's own text: links are not followed.
struct MermaidView: NSViewRepresentable {
    let source: String
    @Binding var height: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> Coordinator { Coordinator(height: $height) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(context.coordinator, name: "height")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        let key = source + (colorScheme == .dark ? "|dark" : "|light")
        guard context.coordinator.loaded != key else { return }
        context.coordinator.loaded = key
        view.loadHTMLString(Self.page(source: source, dark: colorScheme == .dark), baseURL: nil)
    }

    private static let script: String = {
        guard let url = Bundle.module.url(forResource: "mermaid.min", withExtension: "js"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        // Nothing in the script may close the tag it sits in.
        return text.replacingOccurrences(of: "</script", with: "<\\/script")
    }()

    private static func page(source: String, dark: Bool) -> String {
        let escaped = source
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        // The diagram text uses <br/>; Mermaid needs it back after the page has escaped it.
        let text = escaped.replacingOccurrences(of: "&lt;br/&gt;", with: "<br/>")
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>html,body{margin:0;background:transparent;font-family:-apple-system,sans-serif}
        .mermaid{display:flex;justify-content:center}</style></head>
        <body><pre class="mermaid">\(text)</pre>
        <script>\(script)</script>
        <script>
        mermaid.initialize({startOnLoad:false,securityLevel:'strict',theme:'\(dark ? "dark" : "default")',
          flowchart:{htmlLabels:true,curve:'basis'}});
        mermaid.run().then(function(){
          var h=document.documentElement.scrollHeight;
          window.webkit.messageHandlers.height.postMessage(h);
        });
        </script></body></html>
        """
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var loaded = ""
        private let height: Binding<CGFloat>

        init(height: Binding<CGFloat>) { self.height = height }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let value = message.body as? Double, value > 0 else { return }
            let measured = CGFloat(value)
            DispatchQueue.main.async { [height] in
                if abs(height.wrappedValue - measured) > 1 { height.wrappedValue = measured }
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // Only the page that was loaded from text; no link opens inside the diagram.
            decisionHandler(action.navigationType == .other ? .allow : .cancel)
        }
    }
}
