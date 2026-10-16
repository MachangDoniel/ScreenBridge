import AppKit
@preconcurrency import ApplicationServices

/// Paste only into the currently focused editable control; never activate an app or submit.
@MainActor
enum FocusedReferencePaster {
    private static var requestedPermission = false

    static func pasteFromClipboard() -> String {
        guard AXIsProcessTrusted() else {
            if !requestedPermission {
                requestedPermission = true
                _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
            }
            return "Reference copied. Allow ScreenBridge in System Settings → Privacy & Security → Accessibility for automatic paste."
        }
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return "Reference copied. Focus your AI tool’s message field, then paste with ⌘V."
        }
        let system = AXUIElementCreateSystemWide()
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedValue) == .success,
              let focusedValue, CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else {
            return "Reference copied. No editable field is focused; paste with ⌘V when ready."
        }
        let focused = focusedValue as! AXUIElement
        var role: CFTypeRef?
        var subrole: CFTypeRef?
        AXUIElementCopyAttributeValue(focused, kAXRoleAttribute as CFString, &role)
        AXUIElementCopyAttributeValue(focused, kAXSubroleAttribute as CFString, &subrole)
        let editableRole = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role as? String ?? "")
        guard editableRole, subrole as? String != kAXSecureTextFieldSubrole else {
            return "Reference copied. Focus a regular message field to paste it."
        }
        var owner: pid_t = 0
        guard AXUIElementGetPid(focused, &owner) == .success, owner == app.processIdentifier else {
            return "Reference copied. Focus changed; paste with ⌘V when ready."
        }
        // Read-only controls can expose text roles too. Require an insertion point.
        var selection: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused, kAXSelectedTextRangeAttribute as CFString, &selection) == .success else {
            return "Reference copied. No text cursor is available; paste with ⌘V when ready."
        }
        var current: CFTypeRef?
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == owner,
              AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &current) == .success,
              let current, CFEqual(current, focused),
              let down = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: false) else {
            return "Reference copied. Focus changed; paste with ⌘V when ready."
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return "Paste requested in \(app.localizedName ?? "your focused tool"). Type your change request and send when ready."
    }
}
