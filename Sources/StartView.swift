import AppKit

struct VolumeInfo {
    let url: URL, name: String, total: Int64, free: Int64, icon: NSImage
}

func listVolumes() -> [VolumeInfo] {
    let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeLocalizedNameKey]
    let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
    return urls.compactMap { u in
        guard let v = try? u.resourceValues(forKeys: Set(keys)), let t = v.volumeTotalCapacity, t > 0 else { return nil }
        return VolumeInfo(url: u, name: v.volumeLocalizedName ?? v.volumeName ?? u.path, total: Int64(t),
                          free: Int64(v.volumeAvailableCapacity ?? 0), icon: NSWorkspace.shared.icon(forFile: u.path))
    }
}

/// Строка-кнопка на стартовом экране.
final class StartRow: NSControl {
    private let onClick: () -> Void
    private let fraction: Double?
    private var hover = false { didSet { needsDisplay = true } }

    init(icon: NSImage, title: String, detail: String, fraction: Double?, onClick: @escaping () -> Void) {
        self.onClick = onClick
        self.fraction = fraction
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: fraction == nil ? 46 : 60).isActive = true
        let iv = NSImageView(image: icon)
        iv.imageScaling = .scaleProportionallyUpOrDown
        let t = label(title, size: 13, weight: .semibold)
        let d = label(detail, size: 11, color: .secondaryLabelColor)
        for v in [iv, t, d] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            iv.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            iv.centerYAnchor.constraint(equalTo: centerYAnchor),
            iv.widthAnchor.constraint(equalToConstant: 32), iv.heightAnchor.constraint(equalToConstant: 32),
            t.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 12),
            t.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            t.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            d.leadingAnchor.constraint(equalTo: t.leadingAnchor),
            d.topAnchor.constraint(equalTo: t.bottomAnchor, constant: 1),
            d.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with e: NSEvent) { hover = true }
    override func mouseExited(with e: NSEvent) { hover = false }
    override func mouseUp(with e: NSEvent) {
        if bounds.contains(convert(e.locationInWindow, from: nil)) { onClick() }
    }
    override func draw(_ r: NSRect) {
        (hover ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.18) : NSColor.quaternaryLabelColor.withAlphaComponent(0.08)).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 9, yRadius: 9).fill()
        guard let f = fraction else { return }
        let bar = NSRect(x: 56, y: 8, width: bounds.width - 70, height: 6)
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: bar, xRadius: 3, yRadius: 3).fill()
        var u = bar; u.size.width = bar.width * CGFloat(f)
        (f > 0.9 ? NSColor.systemRed : f > 0.75 ? NSColor.systemOrange : NSColor.controlAccentColor).setFill()
        NSBezierPath(roundedRect: u, xRadius: 3, yRadius: 3).fill()
    }
}

final class StartView: NSView {
    private let open: (String) -> Void
    private let choose: () -> Void
    private let stack = NSStackView()

    init(open: @escaping (String) -> Void, choose: @escaping () -> Void) {
        self.open = open; self.choose = choose
        super.init(frame: .zero)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 28, left: 0, bottom: 28, right: 0)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let flip = FlippedView()
        flip.translatesAutoresizingMaskIntoConstraints = false
        flip.addSubview(stack)
        let scroll = NSScrollView(frame: bounds)
        scroll.autoresizingMask = [.width, .height]
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = flip
        addSubview(scroll)
        let clip = scroll.contentView
        NSLayoutConstraint.activate([
            flip.topAnchor.constraint(equalTo: clip.topAnchor),
            flip.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            flip.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            stack.topAnchor.constraint(equalTo: flip.topAnchor),
            stack.bottomAnchor.constraint(equalTo: flip.bottomAnchor),
            stack.centerXAnchor.constraint(equalTo: flip.centerXAnchor),
            stack.widthAnchor.constraint(equalToConstant: 560),
        ])
        rebuild()
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(volumesChanged), name: NSWorkspace.didMountNotification, object: nil)
        nc.addObserver(self, selector: #selector(volumesChanged), name: NSWorkspace.didUnmountNotification, object: nil)
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { NSWorkspace.shared.notificationCenter.removeObserver(self) }

    @objc private func volumesChanged() { rebuild() }

    private func add(_ v: NSView) {
        stack.addArrangedSubview(v)
        v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func section(_ s: String) {
        let l = label(s, size: 11, weight: .semibold, color: .secondaryLabelColor)
        stack.addArrangedSubview(l)
        stack.setCustomSpacing(6, after: l)
    }

    private func rebuild() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let t = label("Что посмотрим?", size: 24, weight: .bold)
        stack.addArrangedSubview(t)
        let sub = label("Выбери диск или папку. Перетащить папку в это окно тоже можно.", size: 13, color: .secondaryLabelColor)
        stack.addArrangedSubview(sub)
        stack.setCustomSpacing(18, after: sub)

        section("ДИСКИ")
        for v in listVolumes() {
            let used = v.total - v.free
            let detail = "Занято \(fmtSize(used)) из \(fmtSize(v.total)), свободно \(fmtSize(v.free))"
            add(StartRow(icon: v.icon, title: v.name, detail: detail, fraction: Double(used) / Double(v.total)) { [open] in open(v.url.path) })
        }
        section("ПАПКИ")
        let home = NSHomeDirectory()
        add(StartRow(icon: NSWorkspace.shared.icon(forFile: home), title: "Домашняя папка", detail: home, fraction: nil) { [open] in open(home) })
        add(StartRow(icon: NSWorkspace.shared.icon(for: .folder), title: "Выбрать папку…", detail: "⌘O", fraction: nil) { [choose] in choose() })
        let recents = Settings.s.recents.filter { FileManager.default.fileExists(atPath: $0) }
        if !recents.isEmpty {
            section("НЕДАВНИЕ")
            for p in recents {
                add(StartRow(icon: NSWorkspace.shared.icon(forFile: p), title: FileManager.default.displayName(atPath: p), detail: p, fraction: nil) { [open] in open(p) })
            }
        }
    }
}

final class FlippedView: NSView { override var isFlipped: Bool { true } }

final class ScanView: NSView {
    private let title = label("", size: 20, weight: .bold)
    private let stats = label("", size: 13)
    private let current = label("", size: 11, color: .secondaryLabelColor)
    private let bar = NSProgressIndicator()
    private let button = NSButton(title: "Отменить", target: nil, action: nil)

    init(path: String, cancel: Selector, target: AnyObject) {
        super.init(frame: .zero)
        title.stringValue = "Сканирую " + FileManager.default.displayName(atPath: path)
        title.alignment = .center
        stats.alignment = .center
        stats.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        current.alignment = .center
        bar.style = .bar
        bar.isIndeterminate = true
        bar.startAnimation(nil)
        button.target = target
        button.action = cancel
        button.keyEquivalent = "\u{1b}"
        let s = NSStackView(views: [title, bar, stats, current, button])
        s.orientation = .vertical
        s.spacing = 12
        s.translatesAutoresizingMaskIntoConstraints = false
        addSubview(s)
        NSLayoutConstraint.activate([
            s.centerXAnchor.constraint(equalTo: centerXAnchor),
            s.centerYAnchor.constraint(equalTo: centerYAnchor),
            s.widthAnchor.constraint(equalToConstant: 460),
            bar.widthAnchor.constraint(equalTo: s.widthAnchor),
            current.widthAnchor.constraint(equalTo: s.widthAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func update(_ p: ScanProgress, expected: Int64?) {
        stats.stringValue = "\(fmtInt(p.files)) файлов · \(fmtInt(p.dirs)) папок · \(fmtSize(p.bytes))"
        current.stringValue = p.current
        if let e = expected, e > 0 {
            if bar.isIndeterminate { bar.stopAnimation(nil); bar.isIndeterminate = false; bar.maxValue = 1 }
            bar.doubleValue = min(1, Double(p.bytes) / Double(e))
        }
    }
}

final class DropView: NSView {
    var onDrop: ((String) -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }
    private func folder(_ s: NSDraggingInfo) -> String? {
        guard let u = s.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])?.first as? URL else { return nil }
        var d: ObjCBool = false
        return FileManager.default.fileExists(atPath: u.path, isDirectory: &d) && d.boolValue ? u.path : nil
    }
    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation { folder(s) != nil ? .generic : [] }
    override func performDragOperation(_ s: NSDraggingInfo) -> Bool {
        guard let p = folder(s) else { return false }
        onDrop?(p)
        return true
    }
}
