import SwiftUI

/// A compact tab bar rendered at the top or bottom of a split pane when
/// the pane has two or more tabs. Hidden for single-tab panes.
struct PaneTabBar: View {
    let tabGroup: SplitTree<Ghostty.SurfaceView>.TabGroup
    let position: Ghostty.Config.PaneTabBarPosition
    let onSelect: (Int) -> Void
    let onClose: (Int) -> Void
    let onNew: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(tabGroup.tabs.enumerated()), id: \.element.id) { index, tab in
                PaneTabButton(
                    title: tab.title.isEmpty ? "Terminal" : tab.title,
                    isActive: index == tabGroup.activeIndex,
                    onSelect: { onSelect(index) },
                    onClose: { onClose(index) }
                )

                if index < tabGroup.tabs.count - 1 {
                    Divider()
                        .frame(height: 16)
                        .opacity(0.3)
                }
            }

            Button(action: onNew) {
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
        .overlay(alignment: position == .bottom ? .top : .bottom) {
            Divider()
        }
    }
}

private struct PaneTabButton: View {
    let title: String
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 4) {
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
