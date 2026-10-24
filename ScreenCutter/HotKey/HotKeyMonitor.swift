import Carbon
import Foundation

final class HotKeyMonitor {
    var onPressed: (UInt32) -> Void = { _ in }

    private var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]
    private var handlerRef: EventHandlerRef?

    func refresh(_ registrations: [HotKeyRegistration]) -> [UInt32: HotKeyConflict] {
        unregisterAll()
        let entries = HotKeyConflictChecker.loadSystemEntries()
        var conflicts: [UInt32: HotKeyConflict] = [:]
        for registration in registrations {
            let system = HotKeyConflictChecker.resolve(entries: entries, carbonStatus: nil, chord: registration.chord)
            if system == .systemShortcut {
                conflicts[registration.id] = .systemShortcut
                continue
            }
            let status = register(registration)
            conflicts[registration.id] = HotKeyConflictChecker.resolve(
                entries: [],
                carbonStatus: status,
                chord: registration.chord
            )
        }
        return conflicts
    }

    func probe(_ chord: HotKeyChord, restoring registrations: [HotKeyRegistration]) -> HotKeyConflict {
        unregisterAll()
        let entries = HotKeyConflictChecker.loadSystemEntries()
        let system = HotKeyConflictChecker.resolve(entries: entries, carbonStatus: nil, chord: chord)
        if system == .systemShortcut {
            _ = refresh(registrations)
            return .systemShortcut
        }
        let status = register(HotKeyRegistration(id: 99, chord: chord))
        unregisterAll()
        _ = refresh(registrations)
        return HotKeyConflictChecker.resolve(entries: [], carbonStatus: status, chord: chord)
    }

    private func register(_ registration: HotKeyRegistration) -> Int32 {
        installHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x5343_5554), id: registration.id)
        let status = RegisterEventHotKey(
            UInt32(registration.chord.keyCode),
            registration.chord.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if status == noErr, let ref {
            hotKeyRefs[registration.id] = ref
        }
        return status
    }

    private func unregisterAll() {
        for ref in hotKeyRefs.values {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let userData else { return noErr }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                let identifier = status == noErr ? hotKeyID.id : 0
                let monitor = Unmanaged<HotKeyMonitor>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        monitor.onPressed(identifier)
                    }
                }
                return noErr
            },
            1,
            &spec,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )
    }
}
