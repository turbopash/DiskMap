import AppKit
import QuartzCore

enum MapTransition {
    case none
    case zoomIn(CGRect)        // прямоугольник плитки в координатах слоя
    case zoomOut(FileNode)     // папка, из которой вышли
}

/// Подсказка у курсора. Мышь сквозь неё проходит.
final class HoverBubble: NSView {
    private let title = NSTextField(labelWithString: "")
    private let info = NSTextField(labelWithString: "")
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.92).cgColor
        layer?.borderColor = NSColor(white: 1, alpha: 0.18).cgColor
        layer?.borderWidth = 0.5
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.textColor = .white
        title.lineBreakMode = .byTruncatingMiddle
        info.font = .systemFont(ofSize: 11)
        info.textColor = NSColor(white: 0.8, alpha: 1)
        info.maximumNumberOfLines = 3
        addSubview(title); addSubview(info)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func set(_ t: String, _ i: String) {
        title.stringValue = t; info.stringValue = i
        let ts = title.intrinsicContentSize, s = info.intrinsicContentSize
        let w = min(380, max(ts.width, s.width) + 20)
        let h = s.height + ts.height + 14
        setFrameSize(NSSize(width: w, height: h))
        title.frame = NSRect(x: 10, y: h - ts.height - 6, width: w - 20, height: ts.height)
        info.frame = NSRect(x: 10, y: 6, width: w - 20, height: s.height)
    }
}

final class MapView: NSView {
    weak var c: MainController?
    private(set) var root: FileNode?
    private(set) var layoutData: TreemapLayout?
    private(set) var image: CGImage?
    var filter = MapFilter() { didSet { if filter != oldValue { schedule(relayout: false) } } }

    private let imageLayer = CALayer()
    private let fxLayer = CALayer()
    private let hoverLayer = CAShapeLayer()
    private let parentLayer = CAShapeLayer()
    private let selLayer = CAShapeLayer()
    private let bubble = HoverBubble(frame: .zero)
    private var bubbleTimer: Timer?
    private let queue = DispatchQueue(label: "map.render", qos: .userInteractive)
    private var generation = 0
    private let genLock = NSLock()
    private var latestStored = 0
    /// Копия номера задания для фоновой очереди: устаревшие задания пропускаются.
    private var latestGeneration: Int {
        get { genLock.lock(); defer { genLock.unlock() }; return latestStored }
        set { genLock.lock(); latestStored = newValue; genLock.unlock() }
    }
    private var needLayout = true
    private var pendingTransition = MapTransition.none
    private var hoverTile: Int?
    private var zoomGesture: CGFloat = 0
    private var wheel: CGFloat = 0
    private var wheelTime = Date.distantPast
    /// Куда возвращает стрелка вниз после подъёма по уровням.
    private var deepest: FileNode?
    var selected: FileNode? { didSet { updateSelection() } }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }
    override var isOpaque: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.backgroundColor = NSColor(white: 0.09, alpha: 1).cgColor
        for l in [imageLayer, fxLayer] {
            l.contentsGravity = .resize
            l.magnificationFilter = .linear
            layer?.addSublayer(l)
        }
        fxLayer.isHidden = true
        parentLayer.strokeColor = NSColor(white: 1, alpha: 0.6).cgColor
        parentLayer.lineWidth = 1
        parentLayer.lineDashPattern = [4, 3]
        hoverLayer.strokeColor = NSColor.white.cgColor
        hoverLayer.lineWidth = 1.5
        selLayer.strokeColor = NSColor(srgbRed: 1, green: 0.9, blue: 0.2, alpha: 1).cgColor
        selLayer.lineWidth = 2.5
        selLayer.shadowColor = NSColor.black.cgColor
        selLayer.shadowOpacity = 0.9
        selLayer.shadowRadius = 2
        selLayer.shadowOffset = .zero
        for l in [parentLayer, hoverLayer, selLayer] {
            l.fillColor = nil
            l.actions = ["path": NSNull(), "hidden": NSNull()]
            layer?.addSublayer(l)
        }
        imageLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        fxLayer.actions = imageLayer.actions
        bubble.isHidden = true
        addSubview(bubble)
    }
    required init?(coder: NSCoder) { fatalError() }

    private var scale: CGFloat { window?.backingScaleFactor ?? 2 }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        imageLayer.frame = bounds
        fxLayer.frame = bounds
        CATransaction.commit()
        schedule(relayout: true)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        for l in [imageLayer, fxLayer] { l.contentsScale = scale }
        schedule(relayout: true)
    }

    func show(_ node: FileNode, transition: MapTransition = .none) {
        root = node
        hoverTile = nil
        hoverLayer.path = nil
        parentLayer.path = nil
        hideBubble()
        schedule(relayout: true, transition: transition)
    }

    // MARK: Рендер

    func currentOptions() -> LayoutOptions {
        let s = Settings.s
        var o = LayoutOptions()
        o.scale = Float(scale)
        o.headers = s.headers
        o.showFree = s.showFree
        o.packagesAsFiles = s.packagesAsFiles
        o.maxDepth = s.maxDepth
        o.height = Float(s.cushionHeight)
        o.falloff = Float(s.cushionFalloff)
        o.minTile = Float(s.minTile)
        return o
    }

    func currentParams() -> RenderParams {
        let s = Settings.s
        var p = RenderParams()
        p.style = s.style
        p.colorMode = s.colorMode
        p.labels = s.labels
        p.ambient = Float(s.ambient)
        p.brightness = Float(s.brightness)
        p.filter = filter
        return p
    }

    func schedule(relayout: Bool, transition: MapTransition = .none) {
        guard let root, bounds.width > 1, bounds.height > 1 else { return }
        if relayout { needLayout = true }
        if case .none = transition {} else { pendingTransition = transition }
        generation += 1
        let gen = generation
        latestGeneration = gen
        let w = (bounds.width * scale).rounded(), h = (bounds.height * scale).rounded()
        let opts = currentOptions(), params = currentParams()
        let cached = needLayout ? nil : layoutData
        queue.async { [weak self] in
            guard let self else { return }
            if gen != self.latestGeneration { return }
            let lay = cached ?? treeLock.read {
                TreemapLayout(root: root, width: Float(w), height: Float(h), opts: opts)
            }
            let img = Renderer.render(lay, params)
            DispatchQueue.main.async {
                guard gen == self.generation else { return }
                self.apply(lay, img)
            }
        }
    }

    private func apply(_ lay: TreemapLayout, _ img: CGImage?) {
        let old = image
        layoutData = lay
        image = img
        needLayout = false
        let tr = pendingTransition
        pendingTransition = .none
        updateSelection()

        CATransaction.begin(); CATransaction.setDisableActions(true)
        switch tr {
        case .none:
            imageLayer.contents = img
        case .zoomIn(let from):
            fxLayer.contents = img
            fxLayer.isHidden = false
            animateFx(from: from, to: bounds, fromOpacity: 0.35, toOpacity: 1) { [weak self] in
                self?.imageLayer.contents = self?.image
            }
        case .zoomOut(let child):
            imageLayer.contents = img
            var target = bounds.insetBy(dx: bounds.width * 0.3, dy: bounds.height * 0.3)
            if let i = lay.tileIndex(for: child) { target = layerRect(lay.rect(i)) }
            fxLayer.contents = old
            fxLayer.isHidden = false
            animateFx(from: bounds, to: target, fromOpacity: 1, toOpacity: 0, done: nil)
        }
        CATransaction.commit()
    }

    private func animateFx(from: CGRect, to: CGRect, fromOpacity: Float, toOpacity: Float, done: (() -> Void)?) {
        let g = CAAnimationGroup()
        let b = CABasicAnimation(keyPath: "bounds")
        b.fromValue = NSValue(rect: CGRect(origin: .zero, size: from.size))
        b.toValue = NSValue(rect: CGRect(origin: .zero, size: to.size))
        let p = CABasicAnimation(keyPath: "position")
        p.fromValue = NSValue(point: CGPoint(x: from.midX, y: from.midY))
        p.toValue = NSValue(point: CGPoint(x: to.midX, y: to.midY))
        let o = CABasicAnimation(keyPath: "opacity")
        o.fromValue = fromOpacity
        o.toValue = toOpacity
        g.animations = [b, p, o]
        g.duration = 0.24
        g.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        g.fillMode = .forwards
        g.isRemovedOnCompletion = false
        CATransaction.setCompletionBlock { [weak self] in
            done?()
            guard let self else { return }
            self.fxLayer.removeAllAnimations()
            self.fxLayer.isHidden = true
            self.fxLayer.contents = nil
        }
        fxLayer.add(g, forKey: "zoom")
    }

    /// Прямоугольник плитки (пиксели, ось вниз) в координатах слоя (точки, ось вверх).
    func layerRect(_ r: CGRect) -> CGRect {
        let s = scale
        return CGRect(x: r.minX / s, y: bounds.height - r.maxY / s, width: r.width / s, height: r.height / s)
    }

    func rectForNode(_ n: FileNode) -> CGRect? {
        guard let lay = layoutData, let i = lay.tileIndex(for: n), i != 0 else { return nil }
        return layerRect(lay.rect(i))
    }

    private func updateSelection() {
        guard let lay = layoutData, let n = selected, let i = lay.tileIndex(for: n), i != 0 || n === lay.root else {
            selLayer.path = nil; return
        }
        selLayer.path = CGPath(rect: layerRect(lay.rect(i)).insetBy(dx: 1.25, dy: 1.25), transform: nil)
    }

    // MARK: Мышь

    private func tile(at e: NSEvent) -> Int? {
        guard let lay = layoutData else { return nil }
        let p = convert(e.locationInWindow, from: nil)
        return lay.hit(x: Float(p.x * scale), y: Float((bounds.height - p.y) * scale))
    }

    override func mouseMoved(with e: NSEvent) {
        guard let lay = layoutData else { return }
        guard let i = tile(at: e) else { clearHover(); return }
        let p = convert(e.locationInWindow, from: nil)
        if i != hoverTile {
            hoverTile = i
            let t = lay.tiles[i]
            hoverLayer.path = CGPath(rect: layerRect(lay.rect(i)).insetBy(dx: 0.75, dy: 0.75), transform: nil)
            if t.parent > 0 {
                parentLayer.path = CGPath(rect: layerRect(lay.rect(Int(t.parent))).insetBy(dx: 0.5, dy: 0.5), transform: nil)
            } else { parentLayer.path = nil }
            c?.hovered(t.node, rest: Int(t.rest))
            if bubble.isHidden {
                bubbleTimer?.invalidate()
                bubbleTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self] _ in self?.showBubble() }
            } else { fillBubble() }
        }
        placeBubble(p)
    }

    private func fillBubble() {
        guard let lay = layoutData, let i = hoverTile, i < lay.tiles.count else { return }
        let t = lay.tiles[i], n = t.node
        if t.rest > 0 {
            bubble.set("\(fmtInt(t.rest)) мелких объектов", "Не помещаются на карте по отдельности\nВ папке \(n.name)")
            return
        }
        var lines = fmtSize(n.size) + " · " + fmtPercent(n.shareOfParent) + (n.isSynthetic ? "" : " от папки")
        if n.isFolder { lines += " · \(fmtInt(n.fileCount)) \(plural(Int(n.fileCount), "файл", "файла", "файлов"))" }
        if !n.isSynthetic { lines += "\nИзменён " + fmtDate(n.mtime) + "\n" + ((n.parent?.path) ?? n.path) }
        bubble.set(n.displayName, lines)
    }

    private func showBubble() {
        guard Settings.s.bubble, hoverTile != nil, let w = window else { return }
        fillBubble()
        bubble.isHidden = false
        placeBubble(convert(w.mouseLocationOutsideOfEventStream, from: nil))
    }

    private func placeBubble(_ p: NSPoint) {
        guard !bubble.isHidden else { return }
        let s = bubble.frame.size
        var x = p.x + 16, y = p.y - s.height - 12
        if x + s.width > bounds.width - 6 { x = p.x - s.width - 12 }
        if y < 6 { y = p.y + 16 }
        bubble.setFrameOrigin(NSPoint(x: max(6, x), y: y))
    }

    private func hideBubble() {
        bubbleTimer?.invalidate()
        bubble.isHidden = true
    }

    private func clearHover() {
        hoverTile = nil
        hoverLayer.path = nil
        parentLayer.path = nil
        hideBubble()
        c?.hovered(nil, rest: 0)
    }

    override func mouseExited(with e: NSEvent) { clearHover() }

    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        hideBubble()
        guard let lay = layoutData, let i = tile(at: e) else { return }
        let n = lay.tiles[i].node
        if e.clickCount >= 2 {
            c?.drill(toward: n)
            return
        }
        var target = n
        if e.modifierFlags.contains(.option), let p = n.parent, !n.isFolder { target = p }
        deepest = target
        c?.select([target], from: self)
    }

    override func menu(for e: NSEvent) -> NSMenu? {
        guard let lay = layoutData, let i = tile(at: e) else { return nil }
        hideBubble()
        let n = lay.tiles[i].node
        deepest = n
        c?.select([n], from: self)
        return c?.contextMenu()
    }

    override func magnify(with e: NSEvent) {
        zoomGesture += e.magnification
        if zoomGesture > 0.3 { zoomGesture = 0; zoomUnderCursor(in: true, e) }
        else if zoomGesture < -0.3 { zoomGesture = 0; zoomUnderCursor(in: false, e) }
        if e.phase == .ended { zoomGesture = 0 }
    }

    override func scrollWheel(with e: NSEvent) {
        // Трекпад шлёт поток мелких значений, зум на нём делается щипком.
        guard !e.hasPreciseScrollingDeltas, e.scrollingDeltaY != 0 else { return }
        if Date().timeIntervalSince(wheelTime) < 0.15 { return }
        wheelTime = Date()
        zoomUnderCursor(in: e.scrollingDeltaY > 0, e)
    }

    private func zoomUnderCursor(in zoomIn: Bool, _ e: NSEvent) {
        if zoomIn {
            if let lay = layoutData, let i = tile(at: e) { c?.drill(toward: lay.tiles[i].node) }
        } else { c?.zoomOut() }
    }

    // MARK: Клавиатура

    override func keyDown(with e: NSEvent) {
        let cmd = e.modifierFlags.contains(.command)
        switch e.keyCode {
        case 49: c?.toggleQuickLook()
        case 36, 76: c?.zoomIntoSelection()
        case 53: c?.escape()
        case 51 where !cmd: c?.zoomOut()
        case 126 where !cmd:
            if let s = selected, let p = s.parent, s !== root { c?.select([p], from: self) }
        case 125 where !cmd:
            guard let s = selected else { selectFirst(); return }
            if let d = deepest, d !== s, d.isDescendant(of: s) {
                var n = d
                while let p = n.parent, p !== s { n = p }
                c?.select([n], from: self)
            } else if let f = s.children.first(where: { !$0.isSynthetic }) {
                deepest = f
                c?.select([f], from: self)
            }
        case 123 where !cmd: sibling(-1)
        case 124 where !cmd: sibling(1)
        default: super.keyDown(with: e)
        }
    }

    private func selectFirst() {
        if let f = root?.children.first { deepest = f; c?.select([f], from: self) }
    }

    private func sibling(_ d: Int) {
        guard let s = selected else { selectFirst(); return }
        guard let p = s.parent, let i = p.children.firstIndex(where: { $0 === s }) else { return }
        let j = i + d
        if p.children.indices.contains(j) {
            deepest = p.children[j]
            c?.select([p.children[j]], from: self)
        }
    }
}
