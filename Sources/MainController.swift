import AppKit
import Quartz

private enum TB {
    static let back = NSToolbarItem.Identifier("back"), forward = NSToolbarItem.Identifier("forward")
    static let up = NSToolbarItem.Identifier("up"), rescan = NSToolbarItem.Identifier("rescan")
    static let color = NSToolbarItem.Identifier("color"), depth = NSToolbarItem.Identifier("depth")
    static let search = NSToolbarItem.Identifier("search"), trash = NSToolbarItem.Identifier("trash")
    static let panel = NSToolbarItem.Identifier("panel")
}

final class MainController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSSearchFieldDelegate,
                            QLPreviewPanelDataSource, QLPreviewPanelDelegate, NSToolbarItemValidation {
    private(set) var root: FileNode?
    private(set) var viewRoot: FileNode?
    private var selected: [FileNode] = []
    private var backStack: [FileNode] = [], forwardStack: [FileNode] = []
    /// Удалённые из дерева узлы живут до следующего полного скана: на них ссылаются parent-указатели.
    private var graveyard: [FileNode] = []
    private var isVolume = false
    private var denied: [String] = []
    private var deniedCount = 0
    private var scanner: Scanner?
    private var scanTimer: Timer?
    private var scanView: ScanView?
    private var replacing: FileNode?
    private var restorePath: String?
    private var filterTitle: String?
    private var uiTestDone: (() -> Void)?

    let map = MapView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    private let drop = DropView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800))
    private var browser: NSView!
    private let split = NSSplitView()
    private let side = NSView(frame: NSRect(x: 0, y: 0, width: 470, height: 700))
    private let tabs = NSSegmentedControl(labels: ["Дерево", "Типы", "Крупные", "Дубликаты"], trackingMode: .selectOne, target: nil, action: nil)
    private let tree = TreePanel(frame: NSRect(x: 0, y: 0, width: 470, height: 660))
    private let types = TypesPanel(frame: NSRect(x: 0, y: 0, width: 470, height: 660))
    private let largest = LargestPanel(frame: NSRect(x: 0, y: 0, width: 470, height: 660))
    private let dups = DuplicatesPanel(frame: NSRect(x: 0, y: 0, width: 470, height: 660))
    private var panels: [Panel] { [tree, types, largest, dups] }
    private let crumbs = NSStackView()
    private let statusLeft = label("", size: 11, color: .secondaryLabelColor)
    private let statusRight = label("", size: 11, color: .secondaryLabelColor)
    private let deniedButton = NSButton(title: "", target: nil, action: nil)
    private let filterButton = NSButton(title: "", target: nil, action: nil)
    private let colorPopup = NSPopUpButton()
    private let depthPopup = NSPopUpButton()
    private var searchItem: NSSearchToolbarItem?

    var filter: MapFilter { map.filter }
    var isIdleStart: Bool { root == nil && scanner == nil }

    init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = "Карта диска"
        w.minSize = NSSize(width: 760, height: 480)
        w.setFrameAutosaveName("DiskMapMain")
        if w.frame.origin == .zero { w.center() }
        w.isReleasedWhenClosed = false
        w.toolbarStyle = .unified
        super.init(window: w)
        w.delegate = self
        map.c = self
        panels.forEach { $0.c = self }
        buildBrowser()
        drop.onDrop = { [weak self] p in (NSApp.delegate as? AppDelegate)?.open(path: p, from: self) }
        w.contentView = drop
        showStart()
        let tb = NSToolbar(identifier: "main")
        tb.delegate = self
        tb.displayMode = .iconOnly
        w.toolbar = tb
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged(_:)), name: .dmSettings, object: nil)
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { NotificationCenter.default.removeObserver(self) }

    private func setContent(_ v: NSView) {
        drop.subviews.forEach { $0.removeFromSuperview() }
        v.frame = drop.bounds
        v.autoresizingMask = [.width, .height]
        drop.addSubview(v)
    }

    func showStart() {
        setContent(StartView(open: { [weak self] p in self?.startScan(p) }, choose: { [weak self] in self?.openFolder(nil) }))
    }

    // MARK: Сборка окна

    private func buildBrowser() {
        let b = NSView(frame: drop.bounds)
        browser = b
        let top = NSView(), bottom = NSView()
        for v in [top, split, bottom] { v.translatesAutoresizingMaskIntoConstraints = false; b.addSubview(v) }

        crumbs.orientation = .horizontal
        crumbs.spacing = 1
        crumbs.translatesAutoresizingMaskIntoConstraints = false
        crumbs.setHuggingPriority(.defaultLow, for: .horizontal)
        top.addSubview(crumbs)

        split.isVertical = true
        split.dividerStyle = .thin
        split.autosaveName = "DiskMapSplit"
        split.addArrangedSubview(map)
        split.addArrangedSubview(side)
        split.setHoldingPriority(.defaultLow - 1, forSubviewAt: 0)
        split.setHoldingPriority(.defaultLow + 1, forSubviewAt: 1)

        tabs.target = self
        tabs.action = #selector(tabChanged)
        tabs.selectedSegment = 0
        tabs.segmentDistribution = .fillEqually
        tabs.translatesAutoresizingMaskIntoConstraints = false
        side.addSubview(tabs)
        let host = NSView()
        host.translatesAutoresizingMaskIntoConstraints = false
        side.addSubview(host)
        NSLayoutConstraint.activate([
            tabs.topAnchor.constraint(equalTo: side.topAnchor, constant: 6),
            tabs.leadingAnchor.constraint(equalTo: side.leadingAnchor, constant: 8),
            tabs.trailingAnchor.constraint(equalTo: side.trailingAnchor, constant: -8),
            host.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 6),
            host.leadingAnchor.constraint(equalTo: side.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: side.trailingAnchor),
            host.bottomAnchor.constraint(equalTo: side.bottomAnchor),
            side.widthAnchor.constraint(greaterThanOrEqualToConstant: 300),
            map.widthAnchor.constraint(greaterThanOrEqualToConstant: 360),
        ])
        for p in panels {
            p.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(p)
            NSLayoutConstraint.activate([
                p.topAnchor.constraint(equalTo: host.topAnchor), p.bottomAnchor.constraint(equalTo: host.bottomAnchor),
                p.leadingAnchor.constraint(equalTo: host.leadingAnchor), p.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            ])
            p.isHidden = p !== tree
        }

        deniedButton.isBordered = false
        deniedButton.target = self
        deniedButton.action = #selector(showDenied)
        deniedButton.font = .systemFont(ofSize: 11)
        deniedButton.contentTintColor = .systemOrange
        deniedButton.isHidden = true
        filterButton.bezelStyle = .inline
        filterButton.controlSize = .small
        filterButton.target = self
        filterButton.action = #selector(clearFilterAction)
        filterButton.isHidden = true
        filterButton.toolTip = "Сбросить фильтр (Esc)"
        statusRight.alignment = .right
        statusRight.setContentHuggingPriority(.required, for: .horizontal)
        statusRight.setContentCompressionResistancePriority(.required, for: .horizontal)
        statusLeft.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for v in [statusLeft, filterButton, deniedButton, statusRight] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            bottom.addSubview(v)
        }
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: b.safeAreaLayoutGuide.topAnchor),
            top.leadingAnchor.constraint(equalTo: b.leadingAnchor),
            top.trailingAnchor.constraint(equalTo: b.trailingAnchor),
            top.heightAnchor.constraint(equalToConstant: 28),
            crumbs.leadingAnchor.constraint(equalTo: top.leadingAnchor, constant: 8),
            crumbs.trailingAnchor.constraint(lessThanOrEqualTo: top.trailingAnchor, constant: -8),
            crumbs.centerYAnchor.constraint(equalTo: top.centerYAnchor),
            split.topAnchor.constraint(equalTo: top.bottomAnchor),
            split.leadingAnchor.constraint(equalTo: b.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: b.trailingAnchor),
            split.bottomAnchor.constraint(equalTo: bottom.topAnchor),
            bottom.leadingAnchor.constraint(equalTo: b.leadingAnchor),
            bottom.trailingAnchor.constraint(equalTo: b.trailingAnchor),
            bottom.bottomAnchor.constraint(equalTo: b.bottomAnchor),
            bottom.heightAnchor.constraint(equalToConstant: 24),
            statusLeft.leadingAnchor.constraint(equalTo: bottom.leadingAnchor, constant: 10),
            statusLeft.centerYAnchor.constraint(equalTo: bottom.centerYAnchor),
            filterButton.leadingAnchor.constraint(greaterThanOrEqualTo: statusLeft.trailingAnchor, constant: 8),
            filterButton.centerYAnchor.constraint(equalTo: bottom.centerYAnchor),
            deniedButton.leadingAnchor.constraint(equalTo: filterButton.trailingAnchor, constant: 8),
            deniedButton.centerYAnchor.constraint(equalTo: bottom.centerYAnchor),
            statusRight.leadingAnchor.constraint(equalTo: deniedButton.trailingAnchor, constant: 10),
            statusRight.trailingAnchor.constraint(equalTo: bottom.trailingAnchor, constant: -10),
            statusRight.centerYAnchor.constraint(equalTo: bottom.centerYAnchor),
        ])
    }

    // MARK: Панель инструментов

    func toolbarAllowedItemIdentifiers(_ t: NSToolbar) -> [NSToolbarItem.Identifier] {
        [TB.back, TB.forward, TB.up, TB.rescan, TB.color, TB.depth, TB.trash, TB.panel, TB.search, .flexibleSpace, .space]
    }
    func toolbarDefaultItemIdentifiers(_ t: NSToolbar) -> [NSToolbarItem.Identifier] {
        [TB.back, TB.forward, TB.up, TB.rescan, .flexibleSpace, TB.color, TB.depth, TB.trash, TB.panel, TB.search]
    }

    func toolbar(_ t: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar f: Bool) -> NSToolbarItem? {
        func button(_ title: String, _ symbol: String, _ action: Selector) -> NSToolbarItem {
            let i = NSToolbarItem(itemIdentifier: id)
            i.label = title
            i.toolTip = title
            i.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            i.target = self
            i.action = action
            i.isBordered = true
            return i
        }
        switch id {
        case TB.back: return button("Назад", "chevron.left", #selector(goBack(_:)))
        case TB.forward: return button("Вперёд", "chevron.right", #selector(goForward(_:)))
        case TB.up: return button("Вверх", "arrow.up", #selector(goUp(_:)))
        case TB.rescan: return button("Пересканировать", "arrow.clockwise", #selector(rescan(_:)))
        case TB.trash: return button("В Корзину", "trash", #selector(moveToTrash(_:)))
        case TB.panel: return button("Боковая панель", "sidebar.right", #selector(togglePanel(_:)))
        case TB.color:
            colorPopup.removeAllItems()
            colorPopup.addItems(withTitles: ColorMode.allCases.map(\.title))
            colorPopup.selectItem(at: Settings.s.colorMode.rawValue)
            colorPopup.target = self
            colorPopup.action = #selector(colorPopupChanged)
            colorPopup.controlSize = .regular
            let i = NSToolbarItem(itemIdentifier: id)
            i.label = "Цвет"
            i.toolTip = "Чем раскрашена карта"
            i.view = colorPopup
            return i
        case TB.depth:
            depthPopup.removeAllItems()
            depthPopup.addItem(withTitle: "Все уровни")
            depthPopup.addItems(withTitles: (1...8).map { "\($0) \(plural($0, "уровень", "уровня", "уровней"))" })
            depthPopup.selectItem(at: min(8, Settings.s.maxDepth))
            depthPopup.target = self
            depthPopup.action = #selector(depthPopupChanged)
            let i = NSToolbarItem(itemIdentifier: id)
            i.label = "Глубина"
            i.toolTip = "Сколько уровней вложенности показывать на карте"
            i.view = depthPopup
            return i
        case TB.search:
            let i = NSSearchToolbarItem(itemIdentifier: id)
            i.searchField.placeholderString = "Поиск по имени"
            i.searchField.target = self
            i.searchField.action = #selector(searchChanged(_:))
            searchItem = i
            return i
        default: return nil
        }
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        switch item.itemIdentifier {
        case TB.back: return !backStack.isEmpty
        case TB.forward: return !forwardStack.isEmpty
        case TB.up: return viewRoot?.parent != nil
        case TB.rescan, TB.panel: return root != nil
        case TB.trash: return !actionNodes().isEmpty
        default: return true
        }
    }

    @objc private func colorPopupChanged() {
        if let m = ColorMode(rawValue: colorPopup.indexOfSelectedItem) { Settings.s.colorMode = m }
    }
    @objc private func depthPopupChanged() { Settings.s.maxDepth = depthPopup.indexOfSelectedItem }

    @objc private func settingsChanged(_ n: Notification) {
        let layout = n.userInfo?["layout"] as? Bool ?? true
        map.schedule(relayout: layout)
        colorPopup.selectItem(at: Settings.s.colorMode.rawValue)
        depthPopup.selectItem(at: min(8, Settings.s.maxDepth))
    }

    // MARK: Сканирование

    func startScan(_ path: String, replacing node: FileNode? = nil) {
        guard scanner == nil else { return }
        let s = Scanner()
        scanner = s
        replacing = node
        let v = ScanView(path: path, cancel: #selector(cancelScan), target: self)
        scanView = v
        setContent(v)
        window?.title = "Карта диска"
        var expected: Int64?
        if node == nil, mountPoints().contains(path), let sp = volumeSpace(path) { expected = sp.total - sp.free }
        if let node { expected = node.alloc }
        scanTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, let s = self.scanner else { return }
            self.scanView?.update(s.snapshot(), expected: expected)
        }
        let excludes = Settings.s.excluded
        let thread = Thread { [weak self] in
            let r = s.scan(path: path, excludes: excludes)
            DispatchQueue.main.async { self?.scanFinished(r, path: path) }
        }
        thread.stackSize = 16 << 20
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    @objc private func cancelScan() { scanner?.cancel() }

    private func scanFinished(_ r: ScanResult?, path: String) {
        scanTimer?.invalidate()
        scanTimer = nil
        scanner = nil
        scanView = nil
        let old = replacing
        replacing = nil
        guard let r else {
            if root != nil { setContent(browser) } else { showStart() }
            return
        }
        if let old, let root {
            treeLock.write {
                replace(old, with: r.root)
                refreshSyntheticNodes(root, isVolume: isVolume)
            }
            graveyard.append(old)
            if let v = viewRoot, v.isDescendant(of: old) { viewRoot = r.root }
            backStack.removeAll { $0.rootNode !== root }
            forwardStack.removeAll { $0.rootNode !== root }
            selected = []
            map.selected = nil
            setContent(browser)
            tree.setRoot(root)
            changedTree()
            return
        }
        Settings.s.recents = [r.root.name] + Settings.s.recents.filter { $0 != r.root.name }
        adopt(r)
    }

    private func adopt(_ r: ScanResult) {
        let keep = restorePath
        restorePath = nil
        let oldRoot = root, oldGrave = graveyard
        graveyard = []
        root = r.root
        isVolume = mountPoints().contains(r.root.name)
        denied = r.deniedPaths
        deniedCount = r.deniedCount
        backStack = []
        forwardStack = []
        selected = []
        map.selected = nil
        viewRoot = r.root
        if let keep, let n = find(path: keep, in: r.root) { viewRoot = n }
        setContent(browser)
        window?.title = r.root.displayName
        window?.representedURL = URL(fileURLWithPath: r.root.name)
        tree.setRoot(r.root)
        map.show(viewRoot!)
        window?.makeFirstResponder(map)
        refreshChrome()
        refreshPanels()
        deniedButton.isHidden = deniedCount == 0
        deniedButton.title = "⚠︎ Нет доступа: \(fmtInt(deniedCount)) \(plural(deniedCount, "папка", "папки", "папок"))"
        window?.toolbar?.validateVisibleItems()
        // Освобождение большого дерева занимает заметное время, главный поток его не ждёт.
        DispatchQueue.global(qos: .background).async { _ = (oldRoot, oldGrave) }
        uiTestDone?()
        uiTestDone = nil
    }

    func onScanDone(_ f: @escaping () -> Void) { uiTestDone = f }

    private func find(path: String, in root: FileNode) -> FileNode? {
        guard path.hasPrefix(root.name) else { return nil }
        var n = root
        for part in path.dropFirst(root.name.count).split(separator: "/") {
            guard let c = n.children.first(where: { $0.name == part }) else { return n }
            n = c
        }
        return n
    }

    @objc func rescan(_ s: Any?) {
        guard let root else { return }
        restorePath = viewRoot?.path
        startScan(root.name)
    }

    @objc func rescanSelection(_ s: Any?) {
        guard let n = actionNodes().first(where: { $0.isFolder }), n.parent != nil else { rescan(nil); return }
        startScan(n.path, replacing: n)
    }

    @objc private func showDenied() {
        let a = NSAlert()
        a.messageText = "Нет доступа к \(fmtInt(deniedCount)) \(plural(deniedCount, "папке", "папкам", "папкам"))"
        a.informativeText = "Их содержимое попало в плитку «Не просканировано». Чтобы карта была полной, включи Карте диска «Полный доступ к диску» в Системных настройках и пересканируй.\n\n"
            + denied.prefix(8).joined(separator: "\n") + (denied.count > 8 ? "\n…" : "")
        a.addButton(withTitle: "Открыть настройки")
        a.addButton(withTitle: "Закрыть")
        a.beginSheetModal(for: window!) { r in
            if r == .alertFirstButtonReturn { openFullDiskAccessSettings() }
        }
    }

    // MARK: Навигация

    func zoom(to n: FileNode, record: Bool = true) {
        guard let cur = viewRoot, n !== cur, n.isFolder else { return }
        if record { backStack.append(cur); forwardStack = [] }
        var tr = MapTransition.none
        if n.isDescendant(of: cur), let r = map.rectForNode(n) { tr = .zoomIn(r) }
        else if cur.isDescendant(of: n) { tr = .zoomOut(cur) }
        viewRoot = n
        map.show(n, transition: tr)
        refreshChrome()
        refreshPanels(onlyVisible: true, skipTree: true)
    }

    /// Двойной щелчок: на уровень глубже в сторону плитки. Файл прямо в открытой папке показывается в Quick Look.
    func drill(toward n: FileNode) {
        guard let cur = viewRoot else { return }
        var x = n
        while let p = x.parent, p !== cur { x = p }
        if x.parent === cur, x.isFolder, !x.children.isEmpty { zoom(to: x) }
        else if !n.isSynthetic && !n.isFolder { select([n], from: nil); toggleQuickLook() }
    }

    func zoomIntoSelection() {
        guard let n = selected.first else { return }
        if n.isFolder && !n.children.isEmpty { zoom(to: n) }
        else if let p = n.parent, p !== viewRoot { zoom(to: p) }
    }

    func zoomOut() { if let p = viewRoot?.parent { zoom(to: p) } }

    func escape() {
        if map.filter.isActive { clearFilter() }
        else if !selected.isEmpty { selected = []; map.selected = nil; refreshStatus() }
    }

    @objc func goUp(_ s: Any?) { zoomOut() }
    @objc func goTop(_ s: Any?) { if let r = root { zoom(to: r) } }
    @objc func zoomIn(_ s: Any?) { zoomIntoSelection() }
    @objc func goBack(_ s: Any?) {
        guard let n = backStack.popLast(), let c = viewRoot else { return }
        forwardStack.append(c)
        zoom(to: n, record: false)
    }
    @objc func goForward(_ s: Any?) {
        guard let n = forwardStack.popLast(), let c = viewRoot else { return }
        backStack.append(c)
        zoom(to: n, record: false)
    }

    @objc private func crumbClicked(_ b: NSButton) {
        var n = viewRoot
        for _ in 0..<b.tag { n = n?.parent }
        if let n { zoom(to: n) }
    }

    private func rebuildCrumbs() {
        crumbs.arrangedSubviews.forEach { $0.removeFromSuperview() }
        var chain: [FileNode] = []
        var n = viewRoot
        while let c = n { chain.append(c); n = c.parent }
        for (i, node) in chain.enumerated().reversed() {
            let b = NSButton(title: node.displayName, target: self, action: #selector(crumbClicked(_:)))
            b.isBordered = false
            b.tag = i
            b.font = .systemFont(ofSize: 12, weight: i == 0 ? .semibold : .regular)
            b.contentTintColor = i == 0 ? .labelColor : .secondaryLabelColor
            b.lineBreakMode = .byTruncatingMiddle
            b.setContentCompressionResistancePriority(i == 0 ? .defaultHigh : .defaultLow, for: .horizontal)
            crumbs.addArrangedSubview(b)
            if i > 0 {
                let sep = label("›", size: 12, color: .tertiaryLabelColor)
                sep.setContentCompressionResistancePriority(.required, for: .horizontal)
                crumbs.addArrangedSubview(sep)
            }
        }
    }

    private func refreshChrome() {
        rebuildCrumbs()
        refreshStatus()
        window?.toolbar?.validateVisibleItems()
    }

    private func refreshStatus() {
        guard let v = viewRoot else { return }
        statusRight.stringValue = "\(fmtSize(v.size)) · \(fmtInt(v.fileCount)) \(plural(Int(v.fileCount), "файл", "файла", "файлов"))"
            + (gUseLogical ? " · логический размер" : "")
        if selected.count > 1 {
            let t = selected.reduce(Int64(0)) { $0 + $1.size }
            statusLeft.stringValue = "Выбрано \(selected.count): \(fmtSize(t))"
        } else if let s = selected.first {
            statusLeft.stringValue = describe(s)
        } else {
            statusLeft.stringValue = "Двойной щелчок: глубже. ⌫: наверх. Пробел: просмотр. Стрелки: выбор уровня."
        }
    }

    private func describe(_ n: FileNode) -> String {
        n.isSynthetic ? "\(n.name): \(fmtSize(n.size))" : "\(n.path) · \(fmtSize(n.size)) · \(fmtPercent(n.shareOfParent))"
    }

    func hovered(_ n: FileNode?, rest: Int) {
        guard let n else { refreshStatus(); return }
        statusLeft.stringValue = rest > 0 ? "\(n.path): \(fmtInt(rest)) мелких объектов" : describe(n)
    }

    // MARK: Выделение и панели

    func select(_ nodes: [FileNode], from src: AnyObject?) {
        selected = nodes
        map.selected = nodes.first
        if src !== tree, nodes.count == 1, !tree.isHidden { tree.reveal(nodes[0]) }
        refreshStatus()
        window?.toolbar?.validateVisibleItems()
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { QLPreviewPanel.shared().reloadData() }
    }

    @objc private func tabChanged() { showTab(tabs.selectedSegment) }

    func showTab(_ i: Int) {
        tabs.selectedSegment = i
        for (k, p) in panels.enumerated() { p.isHidden = k != i }
        if i == 0 { if let s = selected.first { tree.reveal(s) } } else if i != 3 { panels[i].refresh() } else { dups.refresh() }
    }

    func runDuplicatesForTest(_ done: @escaping () -> Void) { showTab(3); dups.runForTest(done) }

    private func refreshPanels(onlyVisible: Bool = true, skipTree: Bool = false) {
        for p in panels where !p.isHidden {
            if p === tree && skipTree { continue }
            p.refresh()
        }
    }

    /// После изменения дерева: заново раскладка, статус и видимая панель.
    private func changedTree() {
        guard let v = viewRoot else { return }
        map.show(v)
        refreshChrome()
        tree.refresh()
        dups.refresh()
        refreshPanels(skipTree: true)
    }

    // MARK: Фильтры

    @objc private func searchChanged(_ f: NSSearchField) {
        var m = map.filter
        m.query = f.stringValue.trimmingCharacters(in: .whitespaces)
        applyFilter(m)
        if !m.query.isEmpty, tabs.selectedSegment != 2 { showTab(2) }
    }

    func setTypeFilter(category: Int?, ext: UInt64?, title: String?) {
        var m = map.filter
        m.category = category
        m.ext = ext
        filterTitle = title
        applyFilter(m)
    }

    private func applyFilter(_ m: MapFilter) {
        map.filter = m
        filterButton.isHidden = !m.isActive
        let parts = [filterTitle, m.query.isEmpty ? nil : "«\(m.query)»"].compactMap { $0 }
        filterButton.title = "✕ " + parts.joined(separator: ", ")
        if !largest.isHidden { largest.refresh() }
    }

    @objc private func clearFilterAction() { clearFilter() }

    private func clearFilter() {
        filterTitle = nil
        searchItem?.searchField.stringValue = ""
        types.clearSelection()
        applyFilter(MapFilter())
    }

    @objc func focusSearch(_ s: Any?) {
        if let i = searchItem { window?.makeFirstResponder(i.searchField) }
    }

    @objc func togglePanel(_ s: Any?) {
        side.isHidden.toggle()
        split.adjustSubviews()
    }

    // MARK: Действия с файлами

    /// Объекты, с которыми работают команды. Служебные плитки сюда не попадают.
    func actionNodes() -> [FileNode] { selected.filter { !$0.isSynthetic } }

    func contextMenu() -> NSMenu {
        let m = NSMenu()
        let nodes = actionNodes()
        func add(_ t: String, _ a: Selector) { m.addItem(withTitle: t, action: a, keyEquivalent: "").target = self }
        if let n = selected.first, n.isSynthetic {
            m.addItem(withTitle: "\(n.name): \(fmtSize(n.size))", action: nil, keyEquivalent: "")
            return m
        }
        guard let n = nodes.first else { return m }
        if nodes.count == 1 {
            if n.isFolder && !n.children.isEmpty { add("Приблизить", #selector(zoomIn(_:))) }
            add("Открыть", #selector(openItem(_:)))
        }
        add("Показать в Finder", #selector(revealInFinder(_:)))
        add("Быстрый просмотр", #selector(quickLook(_:)))
        m.addItem(.separator())
        add("Скопировать путь", #selector(copyPath(_:)))
        if nodes.count == 1 {
            add("Открыть в Терминале", #selector(openTerminal(_:)))
            if n.isFolder && n.parent != nil { add("Пересканировать эту папку", #selector(rescanSelection(_:))) }
            if n.parent != nil { add("Не сканировать больше", #selector(excludeItem(_:))) }
        }
        m.addItem(.separator())
        add("В Корзину", #selector(moveToTrash(_:)))
        add("Удалить навсегда…", #selector(deleteForever(_:)))
        return m
    }

    @objc func openItem(_ s: Any?) {
        for n in actionNodes() { NSWorkspace.shared.open(URL(fileURLWithPath: n.path)) }
    }
    @objc func revealInFinder(_ s: Any?) {
        NSWorkspace.shared.activateFileViewerSelecting(actionNodes().map { URL(fileURLWithPath: $0.path) })
    }
    @objc func copyPath(_ s: Any?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(actionNodes().map(\.path).joined(separator: "\n"), forType: .string)
    }
    @objc func openTerminal(_ s: Any?) {
        guard let n = actionNodes().first else { return }
        let p = n.isFolder ? n.path : (n.parent?.path ?? n.path)
        if let t = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
            NSWorkspace.shared.open([URL(fileURLWithPath: p)], withApplicationAt: t, configuration: NSWorkspace.OpenConfiguration())
        }
    }
    @objc func quickLook(_ s: Any?) { toggleQuickLook() }

    @objc func excludeItem(_ s: Any?) {
        guard let n = actionNodes().first, n.parent != nil else { return }
        Settings.s.excluded = Settings.s.excluded + [n.path]
        removeFromTree([n])
    }

    /// Верхние из выбранных: вложенные в другие выбранные уйдут вместе с ними.
    private func topLevel(_ nodes: [FileNode]) -> [FileNode] {
        nodes.filter { n in !nodes.contains { $0 !== n && n.isDescendant(of: $0) } }
    }

    private func isProtected(_ p: String) -> Bool {
        ["/System", "/usr", "/bin", "/sbin", "/private/var/db", "/Library/Apple"].contains { p == $0 || p.hasPrefix($0 + "/") }
    }

    @objc func moveToTrash(_ s: Any?) { confirmDelete(forever: false) }
    @objc func deleteForever(_ s: Any?) { confirmDelete(forever: true) }

    func confirmDeleteForTest() { confirmDelete(forever: true) }

    private func confirmDelete(forever: Bool) {
        let nodes = topLevel(actionNodes())
        guard !nodes.isEmpty, let w = window else { return }
        let a = NSAlert()
        if nodes.contains(where: { $0.parent == nil }) || nodes.contains(where: { isProtected($0.path) }) {
            a.messageText = "Этот объект удалять нельзя"
            a.informativeText = "Корень карты и системные папки защищены от удаления из программы."
            a.beginSheetModal(for: w)
            return
        }
        let total = nodes.reduce(Int64(0)) { $0 + $1.size }
        let name = nodes.count == 1 ? "«\(nodes[0].name)»" : "\(nodes.count) \(plural(nodes.count, "объект", "объекта", "объектов"))"
        a.messageText = forever ? "Удалить навсегда \(name)?" : "Переместить \(name) в Корзину?"
        var text = "Размер: \(fmtSize(total))."
        if nodes.count == 1 { text += "\n\(nodes[0].path)" }
        else { text += "\n" + nodes.prefix(6).map(\.path).joined(separator: "\n") + (nodes.count > 6 ? "\n…" : "") }
        if forever { text += "\n\nВосстановить будет нельзя." }
        a.informativeText = text
        a.alertStyle = forever ? .critical : .warning
        let b = a.addButton(withTitle: forever ? "Удалить" : "В Корзину")
        b.hasDestructiveAction = true
        a.addButton(withTitle: "Отмена").keyEquivalent = "\u{1b}"
        a.beginSheetModal(for: w) { [weak self] r in
            if r == .alertFirstButtonReturn { self?.performDelete(nodes, forever: forever) }
        }
    }

    func performDelete(_ nodes: [FileNode], forever: Bool) {
        let items = nodes.map { ($0, $0.path) }
        statusLeft.stringValue = "Удаляю…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var done: [FileNode] = []
            var failed: [String] = []
            for (n, p) in items {
                do {
                    if forever { try FileManager.default.removeItem(atPath: p) }
                    else { try FileManager.default.trashItem(at: URL(fileURLWithPath: p), resultingItemURL: nil) }
                    done.append(n)
                } catch { failed.append("\(p): \(error.localizedDescription)") }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.removeFromTree(done)
                if !failed.isEmpty, let w = self.window {
                    let a = NSAlert()
                    a.messageText = "Не удалось удалить: \(failed.count)"
                    a.informativeText = failed.prefix(5).joined(separator: "\n")
                    a.beginSheetModal(for: w)
                }
            }
        }
    }

    private func removeFromTree(_ nodes: [FileNode]) {
        guard let root, !nodes.isEmpty else { return }
        for n in nodes {
            if let v = viewRoot, v.isDescendant(of: n), let p = n.parent { viewRoot = p }
        }
        treeLock.write {
            nodes.forEach(detach)
            refreshSyntheticNodes(root, isVolume: isVolume)
        }
        graveyard += nodes
        backStack.removeAll { $0.rootNode !== root }
        forwardStack.removeAll { $0.rootNode !== root }
        selected = []
        map.selected = nil
        changedTree()
    }

    // MARK: Quick Look

    func toggleQuickLook() {
        guard !actionNodes().isEmpty, let p = QLPreviewPanel.shared() else { return }
        if p.isVisible { p.orderOut(nil) } else { p.makeKeyAndOrderFront(nil) }
    }
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = self; panel.delegate = self }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = nil; panel.delegate = nil }
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { actionNodes().count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt i: Int) -> QLPreviewItem! {
        URL(fileURLWithPath: actionNodes()[i].path) as NSURL
    }

    // MARK: Экспорт

    @objc func openFolder(_ s: Any?) { (NSApp.delegate as? AppDelegate)?.chooseFolder(from: self) }

    @objc func exportPNG(_ s: Any?) {
        guard let img = map.image, let w = window else { return }
        let p = NSSavePanel()
        p.allowedContentTypes = [.png]
        p.nameFieldStringValue = (viewRoot?.displayName ?? "карта") + ".png"
        p.beginSheetModal(for: w) { r in
            if r == .OK, let u = p.url { writePNG(img, u.path) }
        }
    }

    @objc func exportCSV(_ s: Any?) {
        guard let v = viewRoot, let w = window else { return }
        let p = NSSavePanel()
        p.allowedContentTypes = [.commaSeparatedText]
        p.nameFieldStringValue = v.displayName + ".csv"
        p.beginSheetModal(for: w) { r in
            guard r == .OK, let u = p.url else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                var out = "Путь;Занято, байт;Логический размер, байт;Изменён;Тип\n"
                treeLock.read {
                    func walk(_ n: FileNode, _ path: String) {
                        for c in n.children where !c.isSynthetic {
                            let cp = path + "/" + c.name
                            if c.isFolder { walk(c, cp); continue }
                            out += "\"\(cp.replacingOccurrences(of: "\"", with: "\"\""))\";\(c.alloc);\(c.logical);\(fmtDate(c.mtime));\(catNames[Int(c.category)])\n"
                        }
                    }
                    walk(v, v.path == "/" ? "" : v.path)
                }
                try? ("\u{FEFF}" + out).write(to: u, atomically: true, encoding: .utf8)
            }
        }
    }

    // MARK: Настройки из меню

    @objc func setColorMode(_ m: NSMenuItem) { if let c = ColorMode(rawValue: m.tag) { Settings.s.colorMode = c } }
    @objc func setDepth(_ m: NSMenuItem) { Settings.s.maxDepth = m.tag }
    @objc func toggleCushion(_ s: Any?) { Settings.s.style = Settings.s.style == .cushion ? .flat : .cushion }
    @objc func toggleLabels(_ s: Any?) { Settings.s.labels.toggle() }
    @objc func toggleHeaders(_ s: Any?) { Settings.s.headers.toggle() }
    @objc func toggleFree(_ s: Any?) { Settings.s.showFree.toggle() }
    @objc func togglePackages(_ s: Any?) { Settings.s.packagesAsFiles.toggle() }
    @objc func toggleBubble(_ s: Any?) { Settings.s.bubble.toggle() }

    @objc func toggleLogical(_ s: Any?) {
        let v = !gUseLogical
        guard let root else { gUseLogical = v; Settings.s.setLogicalFlag(v); return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            treeLock.write { gUseLogical = v; resortTree(root) }
            DispatchQueue.main.async {
                Settings.s.setLogicalFlag(v)
                self?.changedTree()
            }
        }
    }

    func validateMenuItem(_ m: NSMenuItem) -> Bool { validate(m) }

    private func validate(_ m: NSMenuItem) -> Bool {
        let s = Settings.s
        switch m.action {
        case #selector(setColorMode(_:)): m.state = s.colorMode.rawValue == m.tag ? .on : .off
        case #selector(setDepth(_:)): m.state = s.maxDepth == m.tag ? .on : .off
        case #selector(toggleCushion(_:)): m.state = s.style == .cushion ? .on : .off
        case #selector(toggleLabels(_:)): m.state = s.labels ? .on : .off
        case #selector(toggleHeaders(_:)): m.state = s.headers ? .on : .off
        case #selector(toggleFree(_:)): m.state = s.showFree ? .on : .off
        case #selector(togglePackages(_:)): m.state = s.packagesAsFiles ? .on : .off
        case #selector(toggleBubble(_:)): m.state = s.bubble ? .on : .off
        case #selector(toggleLogical(_:)): m.state = gUseLogical ? .on : .off
        case #selector(goBack(_:)): return !backStack.isEmpty
        case #selector(goForward(_:)): return !forwardStack.isEmpty
        case #selector(goUp(_:)), #selector(goTop(_:)): return viewRoot?.parent != nil
        case #selector(rescan(_:)), #selector(exportPNG(_:)), #selector(exportCSV(_:)), #selector(togglePanel(_:)), #selector(focusSearch(_:)): return root != nil
        case #selector(zoomIn(_:)): return selected.first != nil
        case #selector(openItem(_:)), #selector(revealInFinder(_:)), #selector(copyPath(_:)), #selector(openTerminal(_:)),
             #selector(quickLook(_:)), #selector(moveToTrash(_:)), #selector(deleteForever(_:)), #selector(excludeItem(_:)):
            return !actionNodes().isEmpty
        case #selector(rescanSelection(_:)): return actionNodes().first?.isFolder == true
        default: break
        }
        return true
    }

    func windowWillClose(_ n: Notification) {
        scanner?.cancel()
        scanTimer?.invalidate()
        (NSApp.delegate as? AppDelegate)?.closed(self)
    }
}

func openFullDiskAccessSettings() {
    if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") { NSWorkspace.shared.open(u) }
}
