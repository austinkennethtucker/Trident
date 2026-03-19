import SwiftUI

/// Complete browser pane view with address bar and web content.
struct BrowserPaneView: View {
    @ObservedObject var model: BrowserPaneModel
    @State private var jsInput: String = ""

    var body: some View {
        VStack(spacing: 0) {
            // Address bar
            HStack(spacing: 4) {
                Button(action: { model.goBack() }) {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.plain)
                .disabled(!model.canGoBack)

                Button(action: { model.goForward() }) {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.plain)
                .disabled(!model.canGoForward)

                Button(action: {
                    if model.isLoading {
                        model.stopLoading()
                    } else {
                        model.reload()
                    }
                }) {
                    Image(systemName: model.isLoading ? "xmark" : "arrow.clockwise")
                }
                .buttonStyle(.plain)

                TextField("Enter URL", text: $model.urlString)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        model.navigate(to: model.urlString)
                    }

                // Proxy indicator
                if model.proxyURL != nil {
                    Image(systemName: "shield.lefthalf.filled")
                        .foregroundColor(.orange)
                        .help("Traffic routed through proxy: \(model.proxyURL!)")
                }

                // DOM Inspector toggle
                Button(action: { model.toggleInspectorOverlay() }) {
                    Image(systemName: "eye")
                        .foregroundColor(model.inspectorOverlay?.isActive == true ? .blue : .primary)
                }
                .buttonStyle(.plain)
                .help("Toggle DOM Inspector")

                // JS Console toggle
                Button(action: { model.jsConsoleVisible.toggle() }) {
                    Image(systemName: "terminal")
                        .foregroundColor(model.jsConsoleVisible ? .blue : .primary)
                }
                .buttonStyle(.plain)
                .help("Toggle JS Console")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.bar)

            // Progress bar
            if model.isLoading {
                ProgressView(value: model.estimatedProgress)
                    .progressViewStyle(.linear)
            }

            // Web content
            BrowserWebView(model: model)

            // JS Console panel
            if model.jsConsoleVisible {
                VStack(spacing: 0) {
                    Divider()

                    // Output area
                    ScrollViewReader { proxy in
                        ScrollView {
                            Text(model.jsConsoleOutput.isEmpty ? "Type JavaScript below and press Enter" : model.jsConsoleOutput)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(model.jsConsoleOutput.isEmpty ? .secondary : .primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(4)
                                .textSelection(.enabled)
                                .id("consoleBottom")
                        }
                        .frame(height: 120)
                        .background(Color(nsColor: .textBackgroundColor))
                        .onChange(of: model.jsConsoleOutput) { _ in
                            proxy.scrollTo("consoleBottom", anchor: .bottom)
                        }
                    }

                    Divider()

                    // Input area
                    HStack(spacing: 4) {
                        Text(">")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.orange)
                        TextField("document.title", text: $jsInput)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11, design: .monospaced))
                            .onSubmit {
                                guard !jsInput.isEmpty else { return }
                                model.runJavaScript(jsInput)
                                jsInput = ""
                            }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(nsColor: .controlBackgroundColor))
                }
            }
        }
    }
}
