import SwiftUI

struct ResizableDragHandle: View {
    var onDragDelta: (CGSize, Bool) -> Void

    @State private var previousTranslation = CGSize.zero

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.ultraThinMaterial)
                .frame(width: 32, height: 32)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.black.opacity(0.1))
                )
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        .contentShape(Rectangle())
        .gesture(dragGesture)
        .accessibilityLabel("Resize chat panel")
        .accessibilityHint("Drag diagonally to adjust width and height")
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let delta = CGSize(
                    width: value.translation.width - previousTranslation.width,
                    height: value.translation.height - previousTranslation.height
                )
                previousTranslation = value.translation
                if delta != .zero {
                    onDragDelta(delta, false)
                }
            }
            .onEnded { _ in
                previousTranslation = .zero
                onDragDelta(.zero, true)
            }
    }
}
