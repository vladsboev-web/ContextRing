import Cocoa
import SwiftUI

final class RingPanel: NSPanel {
    private let hostView: DraggableRingHostView

    init(
        viewModel: RingViewModel,
        onMouseDown: @escaping () -> Void,
        onDragStarted: @escaping () -> Void,
        onDragFinished: @escaping (CGPoint) -> Void,
        onClick: @escaping () -> Void,
        onHoverChanged: @escaping (Bool) -> Void
    ) {
        self.hostView = DraggableRingHostView(
            viewModel: viewModel,
            onMouseDown: onMouseDown,
            onDragStarted: onDragStarted,
            onDragFinished: onDragFinished,
            onClick: onClick,
            onHoverChanged: onHoverChanged
        )
        let initialSize = viewModel.effectivePanelSize
        super.init(
            contentRect: CGRect(origin: .zero, size: initialSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isMovable = false
        ignoresMouseEvents = false

        hostView.frame = CGRect(origin: .zero, size: initialSize)
        contentView = hostView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func updatePanelSize(_ newSize: CGSize) {
        let current = frame
        guard abs(current.width - newSize.width) > 0.5 || abs(current.height - newSize.height) > 0.5 else {
            return
        }
        let centeredOrigin = CGPoint(
            x: current.midX - newSize.width / 2.0,
            y: current.midY - newSize.height / 2.0
        )
        setFrame(CGRect(origin: centeredOrigin, size: newSize), display: true)
    }
}

final class DraggableRingHostView: NSView {
    var onMouseDown: () -> Void
    var onDragStarted: () -> Void
    var onDragFinished: (CGPoint) -> Void
    var onClick: () -> Void
    var onHoverChanged: (Bool) -> Void

    private let hostingView: NSHostingView<RingView>
    private var trackingArea: NSTrackingArea?

    private var isPointerDown = false
    private var dragStartMouseLocation: CGPoint?
    private var dragStartWindowOrigin: CGPoint?
    private var didMoveDuringDrag = false

    init(
        viewModel: RingViewModel,
        onMouseDown: @escaping () -> Void,
        onDragStarted: @escaping () -> Void,
        onDragFinished: @escaping (CGPoint) -> Void,
        onClick: @escaping () -> Void,
        onHoverChanged: @escaping (Bool) -> Void
    ) {
        self.onMouseDown = onMouseDown
        self.onDragStarted = onDragStarted
        self.onDragFinished = onDragFinished
        self.onClick = onClick
        self.onHoverChanged = onHoverChanged
        self.hostingView = NSHostingView(rootView: RingView(viewModel: viewModel, interactive: true))
        super.init(frame: CGRect(origin: .zero, size: viewModel.effectivePanelSize))

        hostingView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseEntered(with event: NSEvent) {
        guard !isPointerDown else { return }
        onHoverChanged(true)
    }

    override func mouseExited(with event: NSEvent) {
        guard !isPointerDown else { return }
        onHoverChanged(false)
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        isPointerDown = true
        dragStartMouseLocation = NSEvent.mouseLocation
        dragStartWindowOrigin = window.frame.origin
        didMoveDuringDrag = false
        onMouseDown()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window,
              let startMouse = dragStartMouseLocation,
              let startOrigin = dragStartWindowOrigin else {
            return
        }

        let currentMouse = NSEvent.mouseLocation
        let dx = currentMouse.x - startMouse.x
        let dy = currentMouse.y - startMouse.y

        if !didMoveDuringDrag && hypot(dx, dy) > 3 {
            didMoveDuringDrag = true
            onDragStarted()
        }

        if didMoveDuringDrag {
            let newOrigin = CGPoint(x: startOrigin.x + dx, y: startOrigin.y + dy)
            window.setFrameOrigin(newOrigin)
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            isPointerDown = false
            dragStartMouseLocation = nil
            dragStartWindowOrigin = nil
            didMoveDuringDrag = false
        }

        if didMoveDuringDrag, let window {
            onDragFinished(window.frame.origin)
        } else {
            onClick()
        }
    }
}

struct RingView: View {
    @ObservedObject var viewModel: RingViewModel
    let interactive: Bool

    private var darkTheme: Bool {
        viewModel.effectiveIsDarkTheme
    }

    private var ringSize: CGFloat {
        viewModel.effectiveRingSize
    }

    private var strokeWidth: CGFloat {
        viewModel.effectiveStrokeWidth
    }

    private var badgeFill: Color {
        switch viewModel.ringStyle {
        case .classic:
            return darkTheme
                ? Color(red: 0.12, green: 0.13, blue: 0.15).opacity(0.92)
                : Color.white.opacity(0.94)
        case .minimal:
            return darkTheme
                ? Color.black.opacity(0.28)
                : Color.white.opacity(0.32)
        case .codex:
            return darkTheme
                ? Color(red: 0.08, green: 0.09, blue: 0.11).opacity(0.96)
                : Color(red: 0.96, green: 0.97, blue: 0.99).opacity(0.96)
        }
    }

    private var borderStroke: Color {
        if interactive && viewModel.isDetailOpen {
            let accent = viewModel.hasTokenData ? viewModel.zone.accentColor : Color.gray
            return accent.opacity(0.75)
        }
        if interactive && viewModel.isHoveringRing {
            return darkTheme ? Color.white.opacity(0.34) : Color.black.opacity(0.26)
        }
        switch viewModel.ringStyle {
        case .classic:
            return darkTheme ? Color.white.opacity(0.16) : Color.black.opacity(0.12)
        case .minimal:
            return Color.clear
        case .codex:
            return darkTheme ? Color.white.opacity(0.22) : Color.black.opacity(0.16)
        }
    }

    private var trackColor: Color {
        if !viewModel.hasTokenData {
            return Color.gray.opacity(darkTheme ? 0.42 : 0.35)
        }
        switch viewModel.ringStyle {
        case .classic:
            return darkTheme ? Color.white.opacity(0.14) : Color.black.opacity(0.10)
        case .minimal:
            return darkTheme ? Color.white.opacity(0.22) : Color.black.opacity(0.14)
        case .codex:
            return darkTheme ? Color.white.opacity(0.18) : Color.black.opacity(0.12)
        }
    }

    private var arcColor: Color {
        if !viewModel.hasTokenData {
            return Color.gray.opacity(darkTheme ? 0.50 : 0.45)
        }
        if viewModel.ringStyle == .codex {
            return darkTheme ? Color.white : Color(white: 0.14)
        }
        return viewModel.zone.accentColor
    }

    private var labelColor: Color {
        if !viewModel.hasTokenData {
            return darkTheme ? Color.white.opacity(0.58) : Color.black.opacity(0.45)
        }
        return darkTheme ? Color(white: 0.94) : Color(white: 0.14)
    }

    private var percentText: String {
        viewModel.hasTokenData ? "\(viewModel.percent)%" : "—"
    }

    private var computedFontSize: CGFloat {
        let len = percentText.count
        let baseRatio: CGFloat = len >= 4 ? 0.21 : (len == 3 ? 0.24 : 0.27)
        let raw = ringSize * baseRatio * viewModel.fontSizeScale
        return min(max(raw, 7.0), 28.0)
    }

    private var ringPadding: CGFloat {
        max(2.5, (strokeWidth / 2.0) + (viewModel.ringStyle == .minimal ? 1.5 : 2.5))
    }

    var body: some View {
        let hoverScale: CGFloat = (interactive && viewModel.isHoveringRing) ? 1.04 : 1.0
        let panelSide = ringSize + 6

        ZStack {
            Circle()
                .fill(badgeFill)
                .shadow(
                    color: Color.black.opacity(
                        viewModel.ringStyle == .minimal
                            ? 0.08
                            : (darkTheme ? 0.38 : 0.15)
                    ),
                    radius: (interactive && viewModel.isHoveringRing) ? 3.5 : 2.0,
                    x: 0,
                    y: 1
                )

            if borderStroke != .clear {
                Circle()
                    .stroke(borderStroke, lineWidth: (interactive && viewModel.isDetailOpen) ? 1.5 : 1.0)
            }

            Circle()
                .stroke(trackColor, lineWidth: strokeWidth)
                .padding(ringPadding)

            Circle()
                .trim(from: 0, to: CGFloat(viewModel.progress))
                .stroke(
                    arcColor,
                    style: StrokeStyle(
                        lineWidth: strokeWidth,
                        lineCap: viewModel.ringStyle == .codex ? .butt : .round
                    )
                )
                .rotationEffect(.degrees(-90))
                .padding(ringPadding)
                .animation(.easeOut(duration: 0.22), value: viewModel.progress)

            if viewModel.showPercentInside {
                Text(percentText)
                    .font(.system(size: computedFontSize, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(labelColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, max(2, ringPadding))
            }
        }
        .frame(width: ringSize, height: ringSize)
        .scaleEffect(hoverScale)
        .animation(.easeOut(duration: 0.14), value: hoverScale)
        .frame(width: panelSide, height: panelSide)
    }
}
