import Carbon.HIToolbox
import ShothookCore

/// Global hotkeys via Carbon's RegisterEventHotKey: no Accessibility permission,
/// no event tap, zero cost while idle.
final class HotkeyCenter {
    private var refs: [EventHotKeyRef] = []
    private var actions: [UInt32: () -> Void] = [:]
    private var nextID: UInt32 = 1
    private var handler: EventHandlerRef?

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr else { return status }
            let id = hotKeyID.id
            // Carbon delivers application-target events on the main thread.
            MainActor.assumeIsolated {
                Unmanaged<HotkeyCenter>.fromOpaque(userData).takeUnretainedValue().actions[id]?()
            }
            return noErr
        }, 1, &spec, me, &handler)
    }

    deinit {
        // Owned by the main-actor app delegate, so teardown runs on that actor.
        MainActor.assumeIsolated {
            unregisterAll()
            if let handler { RemoveEventHandler(handler) }
        }
    }

    /// Returns an error message, or nil on success.
    func register(_ hotkey: Hotkey, action: @escaping () -> Void) -> String? {
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(hotkey.keyCode, hotkey.carbonModifiers,
                                         EventHotKeyID(signature: 0x5348_4F54 /* 'SHOT' */, id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            return "couldn't register hotkey \(hotkey.display) (error \(status))"
        }
        refs.append(ref)
        actions[id] = action
        return nil
    }

    func unregisterAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        actions.removeAll()
    }
}
