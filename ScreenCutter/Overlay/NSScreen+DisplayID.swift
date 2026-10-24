import AppKit

extension NSScreen {
    var displayID: CGDirectDisplayID {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return 0
        }
        return CGDirectDisplayID(number.uint32Value)
    }

    /// The current display mode's pixel size plus the screen's AppKit frame. On a
    /// rotated display the mode can report the unrotated dimensions, so pick the
    /// orientation whose aspect actually matches the frame.
    var displayMetrics: DisplayMetrics {
        let id = displayID
        var pixelSize: CGSize

        if let mode = CGDisplayCopyDisplayMode(id), mode.pixelWidth > 0, mode.pixelHeight > 0 {
            var width = CGFloat(mode.pixelWidth)
            var height = CGFloat(mode.pixelHeight)
            let frameWidth = max(frame.width, 1)
            let frameHeight = max(frame.height, 1)
            let directError = abs(width / frameWidth - height / frameHeight)
            let swappedError = abs(height / frameWidth - width / frameHeight)
            if swappedError < directError - 0.01 {
                swap(&width, &height)
            }
            pixelSize = CGSize(width: width, height: height)
        } else {
            pixelSize = CGSize(
                width: frame.width * backingScaleFactor,
                height: frame.height * backingScaleFactor
            )
        }

        return DisplayMetrics(screenID: id, pointFrame: frame, pixelSize: pixelSize)
    }
}
