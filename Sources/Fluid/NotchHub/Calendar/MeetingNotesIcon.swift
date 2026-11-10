import SwiftUI

/// The small mark on a meeting that was recorded: a green disc with a few lines of text, "the notes are here". Drawn in code so no image file is
/// needed; it is a stand-in, not another app's artwork.
struct MeetingNotesIcon: View {
    var size: CGFloat = 24

    var body: some View {
        ZStack {
            Circle().fill(LinearGradient(
                colors: [Color(red: 0.55, green: 0.79, blue: 0.36), Color(red: 0.20, green: 0.58, blue: 0.32)], startPoint: .top, endPoint: .bottom
            ))
            VStack(alignment: .leading, spacing: self.size * 0.085) {
                self.line(0.46)
                self.line(0.34)
                self.line(0.42)
            }
        }
        .frame(width: self.size, height: self.size)
        .contentShape(Circle())
    }

    private func line(_ width: CGFloat) -> some View {
        Capsule().fill(Color.white.opacity(0.95)).frame(width: self.size * width, height: max(1.5, self.size * 0.075))
    }
}
