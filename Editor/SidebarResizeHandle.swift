import SwiftUI

struct SidebarResizeHandle: View {
    enum Side {
        case leading
        case trailing

        var direction: Double {
            switch self {
            case .leading: 1
            case .trailing: -1
            }
        }
    }

    let side: Side
    let isPresented: Bool
    @Binding var width: CGFloat
    let range: ClosedRange<CGFloat>

    @State private var dragStartWidth: CGFloat?

    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(isPresented ? 0.1 : 0))
            .frame(width: isPresented ? 1 : 0)
            .overlay {
                Color.clear
                    .frame(width: isPresented ? 9 : 0)
                    .contentShape(.rect)
                    .gesture(resizeGesture)
            }
            .help(isPresented ? "拖动调整侧边栏宽度" : "")
    }

    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged(resize)
            .onEnded(endResize)
    }

    private func resize(_ value: DragGesture.Value) {
        let initial = dragStartWidth ?? width
        dragStartWidth = initial
        width = min(max(initial + value.translation.width * side.direction, range.lowerBound), range.upperBound)
    }

    private func endResize(_ value: DragGesture.Value) {
        dragStartWidth = nil
    }
}
