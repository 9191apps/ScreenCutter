import AppKit

enum AppAlert {
    /// Returns true when the user chooses the confirm button.
    @discardableResult
    static func show(title: String, message: String, confirm: String = "好", cancel: String? = nil) -> Bool {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirm)
        if let cancel {
            alert.addButton(withTitle: cancel)
        }
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Index of the chosen button, starting at 0.
    static func choose(title: String, message: String, buttons: [String]) -> Int {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        for button in buttons {
            alert.addButton(withTitle: button)
        }
        let response = alert.runModal().rawValue
        return response - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
    }
}
