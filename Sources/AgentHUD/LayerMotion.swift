import AppKit
import QuartzCore
import SwiftUI

/// Бесконечные анимации через Core Animation. Их считает системный рендер-сервер,
/// а не SwiftUI в нашем процессе (SwiftUI тикал бы 120 раз в секунду и ел CPU).
enum LayerMotionKind: Hashable {
    case none
    case sway(amplitude: CGFloat, duration: Double, delay: Double)
    case bounce(amplitude: CGFloat, duration: Double, delay: Double)
    case pulse
}

struct LayerMotion<Content: View>: NSViewRepresentable {
    let kind: LayerMotionKind
    let content: Content

    init(_ kind: LayerMotionKind, @ViewBuilder content: () -> Content) {
        self.kind = kind
        self.content = content()
    }

    func makeNSView(context: Context) -> MotionHostView<Content> {
        MotionHostView(rootView: content)
    }

    func updateNSView(_ v: MotionHostView<Content>, context: Context) {
        v.host.rootView = content
        v.apply(kind)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MotionHostView<Content>, context: Context) -> CGSize? {
        nsView.host.fittingSize
    }
}

final class MotionHostView<Content: View>: NSView {
    let host: NSHostingView<Content>
    private var current: LayerMotionKind = .none

    init(rootView: Content) {
        host = NSHostingView(rootView: rootView)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        host.wantsLayer = true
        host.layer?.masksToBounds = false
        host.autoresizingMask = [.width, .height]
        addSubview(host)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        host.frame = bounds
        // AppKit пересоздаёт параметры слоя при раскладке — анимацию вешаем заново.
        let k = current
        current = .none
        apply(k)
    }

    /// Клики проходят насквозь к SwiftUI-кнопке снаружи.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func apply(_ kind: LayerMotionKind) {
        guard kind != current, let layer = host.layer else { return }
        current = kind
        layer.removeAllAnimations()
        switch kind {
        case .none:
            break
        case .sway(let amp, let dur, let delay):
            layer.add(loop("transform.translation.y", to: amp, dur: dur, delay: delay, timing: .easeInEaseOut), forKey: "motion")
        case .bounce(let amp, let dur, let delay):
            let g = CAAnimationGroup()
            g.animations = [
                loop("transform.translation.y", to: amp, dur: dur, delay: 0, timing: .easeOut),
                loop("transform.scale.y", to: 0.05, dur: dur, delay: 0, timing: .easeOut),
            ]
            g.duration = dur
            g.autoreverses = true
            g.repeatCount = .infinity
            g.beginTime = CACurrentMediaTime() + delay
            g.isRemovedOnCompletion = false
            layer.add(g, forKey: "motion")
        case .pulse:
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = 1
            a.toValue = 0.45
            a.duration = 0.6
            a.autoreverses = true
            a.repeatCount = .infinity
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            a.isRemovedOnCompletion = false
            layer.add(a, forKey: "motion")
        }
    }

    private func loop(_ path: String, to: CGFloat, dur: Double, delay: Double, timing: CAMediaTimingFunctionName) -> CABasicAnimation {
        let a = CABasicAnimation(keyPath: path)
        a.isAdditive = true      // поверх исходного значения, модель слоя не трогаем
        a.fromValue = 0
        a.toValue = to
        a.duration = dur
        a.autoreverses = true
        a.repeatCount = .infinity
        a.beginTime = delay > 0 ? CACurrentMediaTime() + delay : 0
        a.timingFunction = CAMediaTimingFunction(name: timing)
        a.isRemovedOnCompletion = false
        return a
    }
}
