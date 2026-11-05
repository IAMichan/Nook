import Foundation

/// The page a Mermaid diagram draws in. The script ships with Nook (`Resources/mermaid`) and is added by the web view, so a
/// diagram works offline and nothing it says can reach the network: the policy allows no connection, and only inline
/// styles and images. Foundation only, so tests can use it independently.
enum MermaidPage {
    static let policy = "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:; font-src data:"

    static func escaped(_ code: String) -> String {
        code.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
    }

    static func html(_ code: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="\(policy)">
        <style>body{margin:0;padding:12px;background:#0F0F13;color:#F4F3F7;font-family:-apple-system}</style></head>
        <body><pre class="mermaid">\(escaped(code))</pre>
        <script>mermaid.initialize({startOnLoad:true,theme:'dark',securityLevel:'strict'});</script></body></html>
        """
    }
}
