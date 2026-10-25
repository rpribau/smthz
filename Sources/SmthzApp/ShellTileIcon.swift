import SwiftUI

/// The neutral macOS/Linux shell badge from UI-SPEC §1.4 (24-unit artwork).
struct ShellTileIcon: View {
    var size: CGFloat = 12

    var body: some View {
        Canvas { context, bounds in
            let scale = bounds.width / 24
            context.scaleBy(x: scale, y: scale)
            context.fill(Path(roundedRect: CGRect(x: 1.5, y: 3, width: 21, height: 18),
                              cornerRadius: 2.5), with: .color(.black))
            var chevron = Path()
            chevron.move(to: CGPoint(x: 6, y: 7.5))
            chevron.addLine(to: CGPoint(x: 11.5, y: 12))
            chevron.addLine(to: CGPoint(x: 6, y: 16.5))
            context.stroke(chevron, with: .color(.white),
                           style: StrokeStyle(lineWidth: 3.2, lineCap: .round, lineJoin: .round))
            var cursor = Path()
            cursor.move(to: CGPoint(x: 12.5, y: 16.5))
            cursor.addLine(to: CGPoint(x: 18, y: 16.5))
            context.stroke(cursor, with: .color(.white),
                           style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
