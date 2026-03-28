import SwiftUI

/// A compact tab bar for the embedded browser pane, showing one button
/// per open browser tab plus a "+" button to create new tabs.
struct BrowserTabBar: View {
    @ObservedObject var tabManager: BrowserTabManager

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(tabManager.tabs.enumerated()), id: \.element.id) { index, tab in
                BrowserTabButton(
                    title: tabTitle(for: tab.model),
                    isActive: index == tabManager.activeTabIndex,
                    isLoading: tab.model.isLoading,
                    onSelect: { tabManager.selectTab(at: index) },
                    onClose: { tabManager.closeTab(at: index) }
                )

                if index < tabManager.tabs.count - 1 {
                    Divider()
                        .frame(height: 16)
                        .opacity(0.3)
                }
            }

            Button(action: { tabManager.addTab() }) {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 6)

            Spacer()
        }
        .frame(height: 26)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private func tabTitle(for model: BrowserPaneModel) -> String {
        if !model.pageTitle.isEmpty {
            return model.pageTitle
        }
        if let host = model.currentURL?.host {
            return host
        }
        return "New Tab"
    }
}

private struct BrowserTabButton: View {
    let title: String
    let isActive: Bool
    let isLoading: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 4) {
            if isLoading && isActive {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.7)
            }

            Text(title)
                .font(.system(size: 11))
                .lineLimit(1)
                .foregroundStyle(isActive ? .primary : .secondary)

            if isHovering || isActive {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(isActive ? Color.accentColor.opacity(0.1) : Color.clear)
        .cornerRadius(4)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
    }
}
