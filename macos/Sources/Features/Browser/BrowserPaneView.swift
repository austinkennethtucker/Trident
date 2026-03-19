import SwiftUI

/// Complete browser pane view with address bar and web content.
struct BrowserPaneView: View {
    @ObservedObject var model: BrowserPaneModel

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
        }
    }
}
