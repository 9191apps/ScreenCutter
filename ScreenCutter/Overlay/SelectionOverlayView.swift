import Combine
import SwiftUI

struct SelectionOverlayView: View {
    @ObservedObject var session: CaptureSession
    var screenFrame: CGRect
    var scale: CGFloat
    var displayID: CGDirectDisplayID

    var body: some View {
        ZStack {
            dimmedLayer(hole: localSelection)
                .allowsHitTesting(false)
            if let localSelection, let selection {
                selectionChrome(localSelection, label: SelectionGeometry.pixelSizeLabel(
                    globalRect: selection.globalRect,
                    scale: selection.scale
                ))
                .allowsHitTesting(false)
            }
        }
        .frame(width: screenFrame.width, height: screenFrame.height)
    }

    private var selection: ScreenSelection? {
        switch session.phase {
        case .selecting(let drag?):
            guard drag.screenID == displayID else { return nil }
            return ScreenSelection(
                screenID: drag.screenID,
                screenFrame: drag.screenFrame,
                scale: drag.scale,
                globalRect: drag.globalRect
            )
        case .actionBar(let selection):
            guard selection.screenID == displayID else { return nil }
            return selection
        default:
            return nil
        }
    }

    private var localSelection: CGRect? {
        guard let selection else { return nil }
        let local = SelectionGeometry.displayLocalRect(
            selection: selection.globalRect,
            screenFrame: screenFrame
        )
        guard local.width > 0, local.height > 0 else { return nil }
        return local
    }

    private func dimmedLayer(hole: CGRect?) -> some View {
        ZStack {
            Color.black.opacity(0.4)
            if let hole {
                Rectangle()
                    .frame(width: hole.width, height: hole.height)
                    .position(x: hole.midX, y: hole.midY)
                    .blendMode(.destinationOut)
            }
        }
        .compositingGroup()
    }

    private func selectionChrome(_ local: CGRect, label: String) -> some View {
        ZStack {
            Rectangle()
                .stroke(Color.black, lineWidth: 3)
                .frame(width: local.width, height: local.height)
                .position(x: local.midX, y: local.midY)
            Rectangle()
                .stroke(Color.white, lineWidth: 1)
                .frame(width: local.width, height: local.height)
                .position(x: local.midX, y: local.midY)
            Text(label)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.black.opacity(0.72), in: Capsule())
                .position(x: local.midX, y: labelY(for: local))
        }
    }

    private func labelY(for local: CGRect) -> CGFloat {
        if local.minY > 28 {
            return local.minY - 14
        }
        return min(screenFrame.height - 14, local.maxY + 14)
    }
}
