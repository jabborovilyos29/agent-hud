import AppKit
import Combine
import SwiftUI

/// Плавающая панель без активации приложения: не крадёт фокус у терминала,
/// видна на всех рабочих столах и поверх полноэкранных окон.
final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Хостинг SwiftUI, который принимает первый клик даже без фокуса.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class HUDController: NSObject, NSWindowDelegate {
    let panel: HUDPanel
    private let model: AppModel
    private var size = CGSize(width: 80, height: 60)
    private var settingFrame = false
    private var cancellables = Set<AnyCancellable>()

    init(model: AppModel) {
        self.model = model
        panel = HUDPanel(contentRect: NSRect(x: 0, y: 0, width: 80, height: 60),
                         styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        super.init()
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .none
        panel.delegate = self

        let root = HUDRootView(model: model) { [weak self] s in
            Task { @MainActor in self?.contentSizeChanged(s) }
        }
        let host = FirstClickHostingView(rootView: root)
        host.sizingOptions = []
        panel.contentView = host

        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateVisibility() }
            .store(in: &cancellables)
        // Карточку открыли кликом — даём панели фокус клавиатуры (для ⌘↩, Esc и поля ответа).
        model.$selectedKey
            .receive(on: RunLoop.main)
            .sink { [weak self] key in
                guard let self else { return }
                if key != nil, self.model.selectedByUser { self.panel.makeKey() }
            }
            .store(in: &cancellables)
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.placeWindow() }
        }
    }

    var isShown: Bool { panel.isVisible }

    func updateVisibility() {
        let s = model.settings
        let any = !model.visibleSessions.isEmpty
        let shouldShow = s.hudVisible && any && (!s.hideWhenNothingWaits || model.hasAttention || model.selectedKey != nil)
        if shouldShow, !panel.isVisible {
            placeWindow()
            panel.orderFrontRegardless()
        } else if !shouldShow, panel.isVisible {
            panel.orderOut(nil)
        }
    }

    func resetPosition() {
        model.settings.anchor = nil
        placeWindow()
    }

    private func contentSizeChanged(_ s: CGSize) {
        guard s.width > 0, s.height > 0, s != size else { return }
        size = s
        placeWindow()
    }

    /// Правый верхний угол панели держим в одной точке, размер меняется влево и вниз.
    private func placeWindow() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let vf = screen.visibleFrame
        var anchor = model.settings.anchor ?? CGPoint(x: vf.maxX - 2, y: vf.maxY + 2)
        // Не даём уехать за экран (например, после отключения монитора).
        if !NSScreen.screens.contains(where: { $0.frame.insetBy(dx: -4, dy: -4).contains(anchor) }) {
            anchor = CGPoint(x: vf.maxX - 2, y: vf.maxY + 2)
        }
        let frame = NSRect(x: anchor.x - size.width, y: anchor.y - size.height, width: size.width, height: size.height)
        settingFrame = true
        panel.setFrame(frame, display: true)
        settingFrame = false
    }

    nonisolated func windowDidMove(_ notification: Notification) {
        Task { @MainActor in
            guard !self.settingFrame else { return }
            let f = self.panel.frame
            self.model.settings.anchor = CGPoint(x: f.maxX, y: f.maxY)
        }
    }
}
