import SwiftUI
import WebKit

#if os(macOS)
typealias PlatformViewRepresentable = NSViewRepresentable
#elseif os(iOS)
typealias PlatformViewRepresentable = UIViewRepresentable
#endif

#if !os(visionOS)
@available(macOS 11.0, iOS 14.0, *)
public struct MarkdownWebView: PlatformViewRepresentable {
    // Static resources loaded only once
    private struct Resources {
        let templateString: String
        let script: String
        let defaultStylesheet: String
        let katexScript: String
        let katexStyle: String
        let texmathScript: String
        let texmathStyle: String
    }

    private static func loadResource(name: String, ext: String = "", subdir: String) -> String? {
        guard let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: subdir) else {
            print("Failed to load \(name).\(ext) from \(subdir)")
            return nil
        }

        do {
            return try String(contentsOf: url)
        } catch {
            print("Error reading \(name).\(ext): \(error.localizedDescription)")
            return nil
        }
    }

    private static let resources: Resources? = {
        #if os(macOS)
        let defaultStylesheetFileName = "default-macOS"
        #elseif os(iOS)
        let defaultStylesheetFileName = "default-iOS"
        #endif

        // Load all resources
        guard let template = loadResource(name: "template", subdir: "Resources"),
              let script = loadResource(name: "script", subdir: "Resources"),
              let defaultStylesheet = loadResource(name: defaultStylesheetFileName, subdir: "Resources/stylesheets"),
              let katexJs = loadResource(name: "katex", ext: "js", subdir: "Resources/scripts"),
              let katexCss = loadResource(name: "katex", ext: "css", subdir: "Resources/stylesheets"),
              let texmathJs = loadResource(name: "texmath", ext: "js", subdir: "Resources/scripts"),
              let texmathCss = loadResource(name: "texmath", ext: "css", subdir: "Resources/stylesheets")
        else {
            print("Failed to load one or more required resources")
            return nil
        }

        return Resources(
            templateString: template,
            script: script,
            defaultStylesheet: defaultStylesheet,
            katexScript: katexJs,
            katexStyle: katexCss,
            texmathScript: texmathJs,
            texmathStyle: texmathCss
        )
    }()

    // Instance properties
    let markdownContent: String
    let customStylesheet: String?
    let linkActivationHandler: ((URL) -> Void)?
    let renderedContentHandler: ((String) -> Void)?
    let fontSize: CGFloat
    let initialHeight: CGFloat?

    #if os(iOS)
    @Environment(\.scenePhase) private var scenePhase
    #endif

    public init(_ markdownContent: String, customStylesheet: String? = nil, fontSize: CGFloat = 1.0, initialHeight: CGFloat? = nil) {
        self.markdownContent = markdownContent
        self.customStylesheet = customStylesheet
        self.fontSize = fontSize
        self.initialHeight = initialHeight
        linkActivationHandler = nil
        renderedContentHandler = nil
    }

    init(_ markdownContent: String, customStylesheet: String?, fontSize: CGFloat, initialHeight: CGFloat?, linkActivationHandler: ((URL) -> Void)?, renderedContentHandler: ((String) -> Void)?) {
        self.markdownContent = markdownContent
        self.customStylesheet = customStylesheet
        self.fontSize = fontSize
        self.initialHeight = initialHeight
        self.linkActivationHandler = linkActivationHandler
        self.renderedContentHandler = renderedContentHandler
    }

    public func makeCoordinator() -> Coordinator { .init(parent: self) }

    #if os(macOS)
    public func makeNSView(context: Context) -> CustomWebView { context.coordinator.platformView }
    #elseif os(iOS)
    public func makeUIView(context: Context) -> CustomWebView {
        #if os(iOS)
        context.coordinator.currentScenePhase = scenePhase
        #endif
        return context.coordinator.platformView
    }
    #endif

    func updatePlatformView(_ platformView: CustomWebView, context: Context) {
        guard !platformView.isLoading else { return } /// This function might be called when the page is still loading, at which time `window.proxy` is not available yet.

        #if os(iOS)
        // Check if scene phase changed and handle foreground transition
        let coordinator = context.coordinator
        if coordinator.currentScenePhase != scenePhase {
            let previousPhase = coordinator.currentScenePhase
            coordinator.currentScenePhase = scenePhase

            // Even when coming back from the background, previousPhase briefly changes to .inactive before changing to .active
            if scenePhase == .active, previousPhase == .inactive || previousPhase == .background {
                coordinator.handleForegroundTransition()
                return // Return early to let handleForegroundTransition manage the reload
            }
        }
        #endif

        platformView.updateMarkdownContent(markdownContent)
        platformView.updateFontSize(fontSize)
    }

    #if os(macOS)
    public func updateNSView(_ nsView: CustomWebView, context: Context) { updatePlatformView(nsView, context: context) }
    #elseif os(iOS)
    public func updateUIView(_ uiView: CustomWebView, context: Context) { updatePlatformView(uiView, context: context) }
    #endif

    public func onLinkActivation(_ linkActivationHandler: @escaping (URL) -> Void) -> Self {
        .init(markdownContent, customStylesheet: customStylesheet, fontSize: fontSize, initialHeight: initialHeight, linkActivationHandler: linkActivationHandler, renderedContentHandler: renderedContentHandler)
    }

    public func onRendered(_ renderedContentHandler: @escaping (String) -> Void) -> Self {
        .init(markdownContent, customStylesheet: customStylesheet, fontSize: fontSize, initialHeight: initialHeight, linkActivationHandler: linkActivationHandler, renderedContentHandler: renderedContentHandler)
    }

    public class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let parent: MarkdownWebView
        let platformView: CustomWebView

        #if os(iOS)
        var currentScenePhase: ScenePhase = .active
        #endif

        init(parent: MarkdownWebView) {
            self.parent = parent
            platformView = .init()
            platformView.initialHeight = parent.initialHeight
            super.init()

            platformView.navigationDelegate = self

            #if DEBUG && os(iOS)
            if #available(iOS 16.4, *) {
                self.platformView.isInspectable = true
            }
            #endif

            /// So that the `View` adjusts its height automatically.
            platformView.setContentHuggingPriority(.required, for: .vertical)

            /// Disables scrolling.
            #if os(iOS)
            platformView.scrollView.isScrollEnabled = false
            #endif

            /// Set transparent background.
            #if os(macOS)
            platformView.setValue(false, forKey: "drawsBackground")
            /// Equivalent to `.setValue(true, forKey: "drawsTransparentBackground")` on macOS 10.12 and before, which this library doesn't target.
            #elseif os(iOS)
            platformView.isOpaque = false
            #endif

            /// Receive messages from the web view.
            platformView.configuration.userContentController = .init()
            platformView.configuration.userContentController.add(self, name: "sizeChangeHandler")
            platformView.configuration.userContentController.add(self, name: "renderedContentHandler")
            platformView.configuration.userContentController.add(self, name: "copyToPasteboard")

            loadInitialHTML()
            platformView.currentFontSize = parent.fontSize
        }

        #if os(iOS)
        func handleForegroundTransition() {
            print("MarkdownWebView: App returned from background - reloading HTML")
            platformView.invalidateIntrinsicContentSize()
            loadInitialHTML()
        }
        #endif

        func loadInitialHTML() {
            // Use the cached static resources
            guard let resources = MarkdownWebView.resources else {
                print("Failed to load resources.")
                return
            }

            let htmlString = resources.templateString
                .replacingOccurrences(of: "PLACEHOLDER_SCRIPT", with: resources.script)
                .replacingOccurrences(of: "PLACEHOLDER_STYLESHEET", with: parent.customStylesheet ?? resources.defaultStylesheet)
                .replacingOccurrences(of: "PLACEHOLDER_KATEX_SCRIPT", with: resources.katexScript)
                .replacingOccurrences(of: "PLACEHOLDER_KATEX_STYLE", with: resources.katexStyle)
                .replacingOccurrences(of: "PLACEHOLDER_TEXMATH_SCRIPT", with: resources.texmathScript)
                .replacingOccurrences(of: "PLACEHOLDER_TEXMATH_STYLE", with: resources.texmathStyle)
                .replacingOccurrences(of: "PLACEHOLDER_FONT_SIZE_MULTIPLIER", with: String(format: "%.1f", parent.fontSize))
            
            print("MarkdownWebView: Loading initial HTML")
            platformView.loadHTMLString(htmlString, baseURL: nil)
        }

        /// Update the content on first finishing loading.
        public func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
            print("MarkdownWebView: Web view finished loading")
            let customWebView = webView as! CustomWebView
            customWebView.updateMarkdownContent(self.parent.markdownContent)
            customWebView.updateFontSize(self.parent.fontSize)
        }

        /// Reload content if necessary.
        /// The content process may have terminated if the app was in the background and came back to the foreground.
        public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            print("MarkdownWebView: Web content process was terminated. Reloading HTML.")
            let customWebView = webView as! CustomWebView
            // Reset content height to ensure proper sizing after reload
            customWebView.invalidateIntrinsicContentSize()
            loadInitialHTML()
        }

        public func webView(_: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            if navigationAction.navigationType == .linkActivated {
                guard let url = navigationAction.request.url else { return .cancel }

                if let linkActivationHandler = parent.linkActivationHandler {
                    linkActivationHandler(url)
                } else {
                    #if os(macOS)
                    NSWorkspace.shared.open(url)
                    #elseif os(iOS)
                    DispatchQueue.main.async {
                        Task { await UIApplication.shared.open(url) }
                    }
                    #endif
                }

                return .cancel
            } else {
                return .allow
            }
        }

        public func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
            switch message.name {
                case "sizeChangeHandler":
                    guard let contentHeight = message.body as? CGFloat,
                          platformView.contentHeight != contentHeight
                    else { return }
                    platformView.contentHeight = contentHeight
                    platformView.invalidateIntrinsicContentSize()
                case "renderedContentHandler":
                    guard let renderedContentHandler = parent.renderedContentHandler,
                          let renderedContentBase64Encoded = message.body as? String,
                          let renderedContentBase64EncodedData: Data = .init(base64Encoded: renderedContentBase64Encoded),
                          let renderedContent = String(data: renderedContentBase64EncodedData, encoding: .utf8)
                    else { return }
                    renderedContentHandler(renderedContent)
                case "copyToPasteboard":
                    guard let base64EncodedString = message.body as? String else { return }
                    base64EncodedString.trimmingCharacters(in: .whitespacesAndNewlines).copyToPasteboard()
                default:
                    return
            }
        }
    }

    public class CustomWebView: WKWebView {
        var contentHeight: CGFloat = 0
        var initialHeight: CGFloat?
        var currentFontSize: CGFloat = 1.0

        override public var intrinsicContentSize: CGSize {
            let height = contentHeight > 0 ? contentHeight : (initialHeight ?? 0)
            return .init(width: super.intrinsicContentSize.width, height: height)
        }

        /// Disables scrolling
        #if os(macOS)
        override public func scrollWheel(with event: NSEvent) {
            super.scrollWheel(with: event)
            nextResponder?.scrollWheel(with: event)
        }
        #endif

        /// Removes "Reload" from the context menu.
        #if os(macOS)
        override public func willOpenMenu(_ menu: NSMenu, with _: NSEvent) {
            menu.items.removeAll { $0.identifier == .init("WKMenuItemIdentifierReload") }
        }
        #endif

        func updateMarkdownContent(_ markdownContent: String) {
            guard let markdownContentBase64Encoded = markdownContent.data(using: .utf8)?.base64EncodedString() else { 
                print("MarkdownWebView: Failed to encode markdown content to base64")
                return 
            }

            let jsCode = "window.updateWithMarkdownContentBase64Encoded(`\(markdownContentBase64Encoded)`)"
            callAsyncJavaScript(jsCode, in: nil, in: .page) { result in
                if case .failure(let error) = result {
                    print("MarkdownWebView: JavaScript execution error: \(error.localizedDescription)")
                }
            }
        }

        func updateFontSize(_ fontSize: CGFloat) {
            guard fontSize != currentFontSize else { return }
            currentFontSize = fontSize
            
            let jsCode = "window.updateFontSizeMultiplier(\(fontSize))"
            callAsyncJavaScript(jsCode, in: nil, in: .page) { result in
                if case .failure(let error) = result {
                    print("MarkdownWebView: JavaScript execution error: \(error.localizedDescription)")
                }
            }
        }

        #if os(macOS)
        override public func keyDown(with event: NSEvent) {
            nextResponder?.keyDown(with: event)
        }

        override public func keyUp(with event: NSEvent) {
            nextResponder?.keyUp(with: event)
        }

        override public func flagsChanged(with event: NSEvent) {
            nextResponder?.flagsChanged(with: event)
        }

        #elseif os(iOS)
        override public func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            super.pressesBegan(presses, with: event)
            next?.pressesBegan(presses, with: event)
        }

        override public func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            super.pressesEnded(presses, with: event)
            next?.pressesEnded(presses, with: event)
        }

        override public func pressesChanged(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            super.pressesChanged(presses, with: event)
            next?.pressesChanged(presses, with: event)
        }
        #endif
    }
}
#endif

extension String {
    func copyToPasteboard() {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(self, forType: .string)
        #else
        UIPasteboard.general.string = self
        #endif
    }
}
