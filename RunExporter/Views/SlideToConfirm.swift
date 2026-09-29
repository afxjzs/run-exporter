import SwiftUI

/// A control that fires only after a deliberate drag across it.
///
/// Built for controls that must not act on a bump. The phone is carried in one hand for a whole
/// workout with this screen in front, so **Pause** and **Skip** took knocks all run and both were
/// hit by accident: a pause that goes unnoticed costs an interval before it is spotted, and a skip
/// cannot be undone.
///
/// A confirmation dialog would also stop the accident, and is the wrong shape for this moment — a
/// dialog has to be read, and the whole problem is a control being operated without looking. A drag
/// is checkable by feel and cannot happen by brushing the screen.
///
/// Released before the threshold, the thumb springs back and nothing fires.
struct SlideToConfirm: View {

    let title: String
    let systemImage: String
    let action: () -> Void

    @State private var dragOffset: CGFloat = 0
    @State private var hasFired = false

    /// Tall enough to find without looking, and the same height as the buttons it sits among.
    private let height: CGFloat = 60
    private let inset: CGFloat = 4

    /// How far across counts as deliberate. Three quarters, not the whole way: the last stretch of
    /// a drag is where a thumb runs out of room on a wide screen, and the intent is unmistakable
    /// well before that.
    private let threshold: CGFloat = 0.75

    var body: some View {
        GeometryReader { geometry in
            let thumb = height - inset * 2
            let travel = max(1, geometry.size.width - thumb - inset * 2)

            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.12))

                Text(title)
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(maxWidth: .infinity)
                    // Fades as the thumb covers it, so the control reads as progressing rather
                    // than as a label with something sliding over it.
                    .opacity(1 - Double(dragOffset / travel) * 0.9)

                Image(systemName: systemImage)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.black.opacity(0.75))
                    .frame(width: thumb, height: thumb)
                    .background(Circle().fill(.white.opacity(0.9)))
                    .offset(x: inset + dragOffset)
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                guard !hasFired else { return }
                                dragOffset = min(max(0, value.translation.width), travel)
                            }
                            .onEnded { _ in
                                guard !hasFired else { return }
                                if dragOffset >= travel * threshold {
                                    hasFired = true
                                    // Slide the rest of the way before acting, so the gesture is
                                    // seen to complete rather than the screen simply changing.
                                    withAnimation(.easeOut(duration: 0.12)) { dragOffset = travel }
                                    action()
                                } else {
                                    withAnimation(.spring(duration: 0.25)) { dragOffset = 0 }
                                }
                            }
                    )
            }
        }
        .frame(height: height)
        // One element to VoiceOver, activated by the standard gesture: a drag threshold is a
        // defence against an unintended touch, not against someone who has deliberately selected
        // the control and asked for it.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { action() }
    }
}
