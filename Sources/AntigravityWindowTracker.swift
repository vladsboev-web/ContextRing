import ApplicationServices
import Cocoa

/// Tracks the active Antigravity window frame, title, fullscreen state, and Space visibility.
final class AntigravityWindowTracker {
    static let targetBundleId = "com.google.antigravity"

    var onUpdate: ((WindowSnapshot?, Bool) -> Void)?

    private var workspaceObservers: [NSObjectProtocol] = []
    private var pollTimer: Timer?

    private var observedPid: pid_t = 0
    private var axObserver: AXObserver?
    private var observedAppElement: AXUIElement?
    private var observedWindowElement: AXUIElement?
    private var lastTrustedState: Bool = AXIsProcessTrusted()

    deinit {
        stop()
    }

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        let names: [NSNotification.Name] = [
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didDeactivateApplicationNotification,
            NSWorkspace.activeSpaceDidChangeNotification,
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification,
        ]

        for name in names {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refresh()
            }
            workspaceObservers.append(token)
        }

        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        refresh()
    }

    func stop() {
        let center = NSWorkspace.shared.notificationCenter
        for token in workspaceObservers {
            center.removeObserver(token)
        }
        workspaceObservers.removeAll()
        pollTimer?.invalidate()
        pollTimer = nil
        teardownAXObserver()
    }

    func refresh() {
        let trusted = AXIsProcessTrusted()
        if trusted != lastTrustedState {
            lastTrustedState = trusted
            if !trusted {
                teardownAXObserver()
            }
        }

        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              frontApp.bundleIdentifier == Self.targetBundleId,
              !frontApp.isHidden else {
            onUpdate?(nil, trusted)
            return
        }

        let pid = frontApp.processIdentifier
        if trusted {
            ensureAXObserver(for: pid)
        }

        guard let cgWindow = findOnScreenMainCGWindow(for: pid) else {
            onUpdate?(nil, trusted)
            return
        }

        if trusted, let axSnapshot = readAXSnapshot(for: pid, fallbackCGTitle: cgWindow.title) {
            if !axSnapshot.isVisible {
                onUpdate?(nil, trusted)
                return
            }
            onUpdate?(axSnapshot, trusted)
            return
        }

        let isFS = Self.matchesScreenFrame(cgWindow.cocoaFrame)
        let snapshot = WindowSnapshot(
            frame: cgWindow.cocoaFrame,
            title: cgWindow.title,
            isFullScreen: isFS,
            isVisible: true,
            pid: pid
        )
        onUpdate?(snapshot, trusted)
    }

    // MARK: - Accessibility Observer

    private func ensureAXObserver(for pid: pid_t) {
        if observedPid == pid && axObserver != nil {
            attachFocusedWindowNotificationsIfNeeded()
            return
        }
        teardownAXObserver()

        var observer: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            let tracker = Unmanaged<AntigravityWindowTracker>.fromOpaque(refcon).takeUnretainedValue()
            DispatchQueue.main.async {
                tracker.refresh()
            }
        }

        let err = AXObserverCreate(pid, callback, &observer)
        guard err == .success, let observer else {
            return
        }

        let appElement = AXUIElementCreateApplication(pid)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let appNotifications = [
            kAXFocusedWindowChangedNotification,
            kAXMainWindowChangedNotification,
            kAXWindowMovedNotification,
            kAXWindowResizedNotification,
            kAXWindowMiniaturizedNotification,
            kAXWindowDeminiaturizedNotification,
            kAXTitleChangedNotification,
        ]

        for notif in appNotifications {
            let addErr = AXObserverAddNotification(observer, appElement, notif as CFString, selfPtr)
            if addErr != .success && addErr != .notificationAlreadyRegistered {
                // Ignore unsupported notifications on specific Electron builds.
            }
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)

        self.observedPid = pid
        self.axObserver = observer
        self.observedAppElement = appElement
        attachFocusedWindowNotificationsIfNeeded()
    }

    private func attachFocusedWindowNotificationsIfNeeded() {
        guard let observer = axObserver, let appElement = observedAppElement else { return }
        guard let focusedWindow = copyElementAttribute(appElement, attribute: kAXFocusedWindowAttribute)
                ?? copyElementAttribute(appElement, attribute: kAXMainWindowAttribute) else {
            return
        }

        if let existing = observedWindowElement, CFEqual(existing, focusedWindow) {
            return
        }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let windowNotifications = [
            kAXTitleChangedNotification,
            kAXMovedNotification,
            kAXResizedNotification,
        ]

        if let existing = observedWindowElement {
            for notif in windowNotifications {
                AXObserverRemoveNotification(observer, existing, notif as CFString)
            }
        }

        for notif in windowNotifications {
            let addErr = AXObserverAddNotification(observer, focusedWindow, notif as CFString, selfPtr)
            if addErr != .success && addErr != .notificationAlreadyRegistered {
                // Ignore unsupported window-level notifications.
            }
        }
        observedWindowElement = focusedWindow
    }

    private func teardownAXObserver() {
        if let observer = axObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        axObserver = nil
        observedAppElement = nil
        observedWindowElement = nil
        observedPid = 0
    }

    // MARK: - Window Inspection

    private func readAXSnapshot(for pid: pid_t, fallbackCGTitle: String) -> WindowSnapshot? {
        let appElement = observedAppElement ?? AXUIElementCreateApplication(pid)
        guard let windowElement = copyElementAttribute(appElement, attribute: kAXFocusedWindowAttribute)
                ?? copyElementAttribute(appElement, attribute: kAXMainWindowAttribute) else {
            return nil
        }

        if copyBoolAttribute(windowElement, attribute: kAXMinimizedAttribute) == true {
            return WindowSnapshot(frame: .zero, title: "", isFullScreen: false, isVisible: false, pid: pid)
        }

        guard let quartzPos = copyPointAttribute(windowElement, attribute: kAXPositionAttribute),
              let size = copySizeAttribute(windowElement, attribute: kAXSizeAttribute),
              size.width >= 200, size.height >= 150 else {
            return nil
        }

        let cocoaFrame = Self.quartzToCocoaRect(CGRect(origin: quartzPos, size: size))
        let axTitle = copyStringAttribute(windowElement, attribute: kAXTitleAttribute) ?? ""
        let title = !axTitle.isEmpty ? axTitle : fallbackCGTitle
        let isFS = copyBoolAttribute(windowElement, attribute: "AXFullScreen")
            ?? Self.matchesScreenFrame(cocoaFrame)

        return WindowSnapshot(
            frame: cocoaFrame,
            title: title,
            isFullScreen: isFS,
            isVisible: true,
            pid: pid
        )
    }

    private func findOnScreenMainCGWindow(for pid: pid_t) -> (cocoaFrame: CGRect, title: String)? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        var bestFrame: CGRect?
        var bestTitle = ""
        var bestArea: CGFloat = 0

        for item in list {
            guard (item[kCGWindowOwnerPID as String] as? pid_t) == pid else { continue }
            let layer = item[kCGWindowLayer as String] as? Int ?? -1
            guard layer == 0 else { continue }

            guard let boundsDict = item[kCGWindowBounds as String] as? NSDictionary,
                  let quartzRect = CGRect(dictionaryRepresentation: boundsDict),
                  quartzRect.width >= 200,
                  quartzRect.height >= 150 else {
                continue
            }

            let area = quartzRect.width * quartzRect.height
            if area > bestArea {
                bestArea = area
                bestFrame = Self.quartzToCocoaRect(quartzRect)
                bestTitle = (item[kCGWindowName as String] as? String) ?? ""
            }
        }

        guard let frame = bestFrame else { return nil }
        return (frame, bestTitle)
    }

    // MARK: - One-shot Send Button Locator (AXManualAccessibility)

    func locateSendButton(in snapshot: WindowSnapshot) -> CGRect? {
        guard AXIsProcessTrusted() else { return nil }

        let appElement = AXUIElementCreateApplication(snapshot.pid)
        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)

        guard let windowElement = copyElementAttribute(appElement, attribute: kAXFocusedWindowAttribute)
                ?? copyElementAttribute(appElement, attribute: kAXMainWindowAttribute) else {
            return nil
        }

        var queue: [(element: AXUIElement, depth: Int)] = [(windowElement, 0)]
        var visited = 0
        let maxNodes = 1500
        let maxDepth = 25
        let keywords = ["send", "submit", "отправ"]
        let lowerHalfLimitY = snapshot.frame.midY

        var idx = 0
        while idx < queue.count && visited < maxNodes {
            let current = queue[idx]
            idx += 1
            visited += 1

            let role = copyStringAttribute(current.element, attribute: kAXRoleAttribute) ?? ""
            if role == (kAXButtonRole as String) {
                let labels = [
                    copyStringAttribute(current.element, attribute: kAXTitleAttribute) ?? "",
                    copyStringAttribute(current.element, attribute: kAXDescriptionAttribute) ?? "",
                    copyStringAttribute(current.element, attribute: kAXHelpAttribute) ?? "",
                ]
                let combined = labels.joined(separator: " ").lowercased()
                if keywords.contains(where: { combined.contains($0) }),
                   let pos = copyPointAttribute(current.element, attribute: kAXPositionAttribute),
                   let size = copySizeAttribute(current.element, attribute: kAXSizeAttribute),
                   size.width > 8, size.height > 8 {
                    let cocoaRect = Self.quartzToCocoaRect(CGRect(origin: pos, size: size))
                    if cocoaRect.midY <= lowerHalfLimitY {
                        return cocoaRect
                    }
                }
            }

            if current.depth < maxDepth,
               let children = copyChildrenAttribute(current.element) {
                for child in children {
                    queue.append((child, current.depth + 1))
                }
            }
        }
        return nil
    }

    // MARK: - Coordinate & AX Helpers

    private static func quartzToCocoaRect(_ quartzRect: CGRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 900
        let cocoaY = primaryHeight - quartzRect.origin.y - quartzRect.height
        return CGRect(
            x: quartzRect.origin.x,
            y: cocoaY,
            width: quartzRect.width,
            height: quartzRect.height
        )
    }

    private static func matchesScreenFrame(_ cocoaFrame: CGRect) -> Bool {
        for screen in NSScreen.screens {
            let sf = screen.frame
            if abs(cocoaFrame.origin.x - sf.origin.x) <= 4,
               abs(cocoaFrame.origin.y - sf.origin.y) <= 4,
               abs(cocoaFrame.width - sf.width) <= 4,
               abs(cocoaFrame.height - sf.height) <= 4 {
                return true
            }
        }
        return false
    }

    private func copyElementAttribute(_ element: AXUIElement, attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return (value as! AXUIElement)
    }

    private func copyStringAttribute(_ element: AXUIElement, attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private func copyBoolAttribute(_ element: AXUIElement, attribute: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return (value as? NSNumber)?.boolValue
    }

    private func copyPointAttribute(_ element: AXUIElement, attribute: String) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        let axVal = value as! AXValue
        var point = CGPoint.zero
        guard AXValueGetValue(axVal, .cgPoint, &point) else { return nil }
        return point
    }

    private func copySizeAttribute(_ element: AXUIElement, attribute: String) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        let axVal = value as! AXValue
        var size = CGSize.zero
        guard AXValueGetValue(axVal, .cgSize, &size) else { return nil }
        return size
    }

    private func copyChildrenAttribute(_ element: AXUIElement) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let array = value as? [AXUIElement] else {
            return nil
        }
        return array
    }
}
