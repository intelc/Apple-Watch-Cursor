import AppKit
import ApplicationServices
import AppleWatchCursorCore

@MainActor
final class PointerController {
    var hasPermission: Bool { AXIsProcessTrusted() }

    func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private var activeDisplay: CGDirectDisplayID = CGMainDisplayID()
    func selectPrimaryDisplay() { activeDisplay = CGMainDisplayID() }

    func move(x: Double, y: Double) {
        guard hasPermission, x.isFinite, y.isFinite else { return }
        let bounds = CGDisplayBounds(activeDisplay)
        guard bounds.width > 0, bounds.height > 0 else { return }
        let point = CGPoint(x: bounds.midX + min(1, max(-1, x)) * (bounds.width/2-2),
                            y: bounds.midY + min(1, max(-1, y)) * (bounds.height/2-2))
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point,
                mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    func click(x: Double, y: Double) {
        guard hasPermission, x.isFinite, y.isFinite else { return }
        let bounds = CGDisplayBounds(activeDisplay)
        guard bounds.width > 0, bounds.height > 0 else { return }
        let point = CGPoint(x: bounds.midX + min(1,max(-1,x))*(bounds.width/2-2),
                            y: bounds.midY + min(1,max(-1,y))*(bounds.height/2-2))
        guard let down = CGEvent(mouseEventSource: nil,mouseType: .leftMouseDown,mouseCursorPosition: point,mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil,mouseType: .leftMouseUp,mouseCursorPosition: point,mouseButton: .left) else { return }
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
    }
}
