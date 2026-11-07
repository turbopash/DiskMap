import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var windows: [MainController] = []
    private var prefs: PrefsController?
    private var pending: [String] = []
    private var launched = false

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.mainMenu = buildMenu()
        launched = true
        if uiTestArgs != nil {} else if pending.isEmpty { newWindow(nil) } else { pending.forEach { open(path: $0, from: nil) } }
        pending = []
        if let test = uiTestArgs { if test.first == "flow" { runFlowTest(self) } else { runUITest(test, self) } } else { NSApp.activate(ignoringOtherApps: true) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }

    func application(_ s: NSApplication, open urls: [URL]) {
        for u in urls {
            if launched { open(path: u.path, from: nil) } else { pending.append(u.path) }
        }
    }

    func validateMenuItem(_ m: NSMenuItem) -> Bool { true }

    @discardableResult func makeWindow() -> MainController {
        let c = MainController()
        windows.append(c)
        c.showWindow(nil)
        return c
    }

    @objc func newWindow(_ s: Any?) { makeWindow() }

    func closed(_ c: MainController) {
        DispatchQueue.main.async { self.windows.removeAll { $0 === c } }
    }

    func open(path: String, from c: MainController?) {
        let target = (c?.isIdleStart == true ? c : nil) ?? windows.first { $0.isIdleStart } ?? makeWindow()
        target.window?.makeKeyAndOrderFront(nil)
        target.startScan(path)
    }

    func chooseFolder(from c: MainController?) {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.prompt = "Сканировать"
        p.message = "Выбери папку или диск"
        p.begin { [weak self] r in
            if r == .OK, let u = p.url { self?.open(path: u.path, from: c) }
        }
    }

    @objc func openFolder(_ s: Any?) { chooseFolder(from: nil) }

    @objc func showPrefs(_ s: Any?) {
        if prefs == nil { prefs = PrefsController() }
        prefs?.showWindow(nil)
    }

    @objc func showFullDiskAccess(_ s: Any?) { openFullDiskAccessSettings() }

    private func buildMenu() -> NSMenu {
        let main = NSMenu()
        func sub(_ title: String) -> NSMenu {
            let m = NSMenu(title: title)
            let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            i.submenu = m
            main.addItem(i)
            return m
        }
        func add(_ m: NSMenu, _ t: String, _ a: Selector?, _ k: String = "", _ mods: NSEvent.ModifierFlags = .command, tag: Int = 0) {
            let i = NSMenuItem(title: t, action: a, keyEquivalent: k)
            i.keyEquivalentModifierMask = mods
            i.tag = tag
            m.addItem(i)
        }
        let C = MainController.self
        _ = C
        let app = sub("Карта диска")
        add(app, "О программе", #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
        app.addItem(.separator())
        add(app, "Настройки…", #selector(showPrefs(_:)), ",")
        add(app, "Открыть «Полный доступ к диску»", #selector(showFullDiskAccess(_:)))
        app.addItem(.separator())
        add(app, "Скрыть", #selector(NSApplication.hide(_:)), "h")
        add(app, "Скрыть остальные", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
        add(app, "Показать все", #selector(NSApplication.unhideAllApplications(_:)))
        app.addItem(.separator())
        add(app, "Завершить", #selector(NSApplication.terminate(_:)), "q")

        let file = sub("Файл")
        add(file, "Новое окно", #selector(newWindow(_:)), "n")
        add(file, "Открыть папку…", #selector(openFolder(_:)), "o")
        add(file, "Пересканировать", #selector(MainController.rescan(_:)), "r")
        add(file, "Пересканировать выбранную папку", #selector(MainController.rescanSelection(_:)), "r", [.command, .shift])
        file.addItem(.separator())
        add(file, "Сохранить карту как PNG…", #selector(MainController.exportPNG(_:)), "e")
        add(file, "Сохранить список файлов как CSV…", #selector(MainController.exportCSV(_:)), "e", [.command, .shift])
        file.addItem(.separator())
        add(file, "Закрыть", #selector(NSWindow.performClose(_:)), "w")

        let edit = sub("Правка")
        add(edit, "Вырезать", #selector(NSText.cut(_:)), "x")
        add(edit, "Скопировать", #selector(NSText.copy(_:)), "c")
        add(edit, "Вставить", #selector(NSText.paste(_:)), "v")
        add(edit, "Выбрать всё", #selector(NSText.selectAll(_:)), "a")
        edit.addItem(.separator())
        add(edit, "Искать…", #selector(MainController.focusSearch(_:)), "f")

        let item = sub("Объект")
        add(item, "Открыть", #selector(MainController.openItem(_:)), "\r")
        add(item, "Показать в Finder", #selector(MainController.revealInFinder(_:)), "r", [.command, .option])
        add(item, "Быстрый просмотр", #selector(MainController.quickLook(_:)), "y")
        add(item, "Скопировать путь", #selector(MainController.copyPath(_:)), "c", [.command, .option])
        add(item, "Открыть в Терминале", #selector(MainController.openTerminal(_:)), "t", [.command, .option])
        item.addItem(.separator())
        add(item, "Не сканировать больше", #selector(MainController.excludeItem(_:)))
        item.addItem(.separator())
        add(item, "В Корзину", #selector(MainController.moveToTrash(_:)), "\u{8}")
        add(item, "Удалить навсегда…", #selector(MainController.deleteForever(_:)), "\u{8}", [.command, .option])

        let view = sub("Вид")
        for m in ColorMode.allCases {
            add(view, m.title, #selector(MainController.setColorMode(_:)), "\(m.rawValue + 1)", .command, tag: m.rawValue)
        }
        view.addItem(.separator())
        let depth = NSMenu(title: "Глубина")
        add(depth, "Все уровни", #selector(MainController.setDepth(_:)), tag: 0)
        for d in 1...8 { add(depth, "\(d)", #selector(MainController.setDepth(_:)), tag: d) }
        let di = NSMenuItem(title: "Глубина", action: nil, keyEquivalent: "")
        di.submenu = depth
        view.addItem(di)
        view.addItem(.separator())
        add(view, "Объёмные подушки", #selector(MainController.toggleCushion(_:)), "k")
        add(view, "Подписи на плитках", #selector(MainController.toggleLabels(_:)), "l")
        add(view, "Рамки и заголовки папок", #selector(MainController.toggleHeaders(_:)), "h", [.command, .shift])
        add(view, "Свободное место на карте", #selector(MainController.toggleFree(_:)))
        add(view, "Пакеты как один файл", #selector(MainController.togglePackages(_:)))
        add(view, "Подсказка у курсора", #selector(MainController.toggleBubble(_:)))
        view.addItem(.separator())
        add(view, "Логический размер вместо занятого", #selector(MainController.toggleLogical(_:)))
        view.addItem(.separator())
        add(view, "Боковая панель", #selector(MainController.togglePanel(_:)), "s", [.command, .option])
        add(view, "Во весь экран", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])

        let go = sub("Переход")
        add(go, "Назад", #selector(MainController.goBack(_:)), "[")
        add(go, "Вперёд", #selector(MainController.goForward(_:)), "]")
        add(go, "Приблизить выбранное", #selector(MainController.zoomIn(_:)), String(UnicodeScalar(NSDownArrowFunctionKey)!))
        add(go, "На уровень выше", #selector(MainController.goUp(_:)), String(UnicodeScalar(NSUpArrowFunctionKey)!))
        add(go, "К корню", #selector(MainController.goTop(_:)), String(UnicodeScalar(NSUpArrowFunctionKey)!), [.command, .shift])

        let win = sub("Окно")
        add(win, "Свернуть", #selector(NSWindow.performMiniaturize(_:)), "m")
        add(win, "Масштаб", #selector(NSWindow.performZoom(_:)))
        NSApp.windowsMenu = win
        return main
    }
}

final class PrefsController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let table = NSTableView()
    private var sliders: [(NSSlider, ReferenceWritableKeyPath<Settings, Double>)] = []
    private var excluded = Settings.s.excluded

    init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 470), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Настройки"
        w.isReleasedWhenClosed = false
        w.center()
        super.init(window: w)
        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 10
        func slider(_ title: String, _ k: ReferenceWritableKeyPath<Settings, Double>, _ lo: Double, _ hi: Double) {
            let s = NSSlider(value: Settings.s[keyPath: k], minValue: lo, maxValue: hi, target: self, action: #selector(sliderMoved(_:)))
            s.widthAnchor.constraint(equalToConstant: 280).isActive = true
            sliders.append((s, k))
            grid.addRow(with: [label(title), s])
        }
        slider("Высота подушек", \.cushionHeight, 0, 0.5)
        slider("Спад по уровням", \.cushionFalloff, 0.3, 1)
        slider("Мягкость теней", \.ambient, 0.05, 0.8)
        slider("Яркость", \.brightness, 0.7, 1.5)
        slider("Мельчайшая плитка", \.minTile, 1, 12)

        table.addTableColumn(makeColumn("p", "Папки, которые не сканируются", 420))
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 20
        table.allowsMultipleSelection = true
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        let scroll = wrapScroll(table)
        scroll.borderType = .bezelBorder
        let add = NSButton(title: "Добавить…", target: self, action: #selector(addPath))
        let rm = NSButton(title: "Убрать", target: self, action: #selector(removePath))
        let reset = NSButton(title: "Вид по умолчанию", target: self, action: #selector(resetLook))
        let fda = NSButton(title: "Полный доступ к диску…", target: self, action: #selector(fullAccess))
        let row = NSStackView(views: [add, rm, NSView(), reset])
        row.distribution = .fill
        let note = label("Без полного доступа часть папок попадает в плитку «Не просканировано». После пересборки программы разрешение надо выдать заново.", size: 11, color: .secondaryLabelColor)
        note.maximumNumberOfLines = 3
        note.lineBreakMode = .byWordWrapping
        let stack = NSStackView(views: [grid, scroll, row, fda, note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let c = w.contentView!
        c.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: c.topAnchor), stack.bottomAnchor.constraint(equalTo: c.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: c.leadingAnchor), stack.trailingAnchor.constraint(equalTo: c.trailingAnchor),
            scroll.widthAnchor.constraint(equalToConstant: 440), scroll.heightAnchor.constraint(equalToConstant: 120),
            row.widthAnchor.constraint(equalToConstant: 440), note.widthAnchor.constraint(equalToConstant: 440),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func sliderMoved(_ s: NSSlider) {
        if let (_, k) = sliders.first(where: { $0.0 === s }) { Settings.s[keyPath: k] = s.doubleValue }
    }
    @objc private func resetLook() {
        Settings.s.resetCushion()
        for (s, k) in sliders { s.doubleValue = Settings.s[keyPath: k] }
    }
    @objc private func fullAccess() { openFullDiskAccessSettings() }
    @objc private func addPath() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.allowsMultipleSelection = true
        p.begin { [weak self] r in
            guard r == .OK, let self else { return }
            self.excluded += p.urls.map(\.path)
            self.save()
        }
    }
    @objc private func removePath() {
        for i in table.selectedRowIndexes.reversed() { excluded.remove(at: i) }
        save()
    }
    private func save() {
        Settings.s.excluded = excluded
        table.reloadData()
    }
    override func showWindow(_ s: Any?) {
        excluded = Settings.s.excluded
        table.reloadData()
        super.showWindow(s)
    }
    func numberOfRows(in t: NSTableView) -> Int { excluded.count }
    func tableView(_ t: NSTableView, viewFor c: NSTableColumn?, row: Int) -> NSView? { textCell(t, excluded[row], right: false) }
}

var uiTestArgs: [String]?

func runApp() {
    let app = NSApplication.shared
    let d = AppDelegate()
    app.delegate = d
    app.setActivationPolicy(.regular)
    app.run()
}

/// Прогон настоящего окна: скан, выделение, зум, панели, фильтр. Снимки окна кладутся в папку.
func runUITest(_ a: [String], _ d: AppDelegate) {
    let path = a[0], out = a[1]
    let c = d.makeWindow()
    c.window?.setContentSize(NSSize(width: 1400, height: 860))
    func shot(_ name: String) {
        guard let w = c.window, let frame = w.contentView?.superview else { return }
        guard let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { return }
        frame.cacheDisplay(in: frame.bounds, to: rep)
        // Карта живёт в отдельных слоях, cacheDisplay их не видит. Слои дорисовываются поверх.
        if let g = NSGraphicsContext(bitmapImageRep: rep), let l = c.map.layer, c.map.window != nil, !c.map.isHiddenOrHasHiddenAncestor {
            let r = c.map.convert(c.map.bounds, to: frame)
            let cg = g.cgContext
            cg.saveGState()
            cg.translateBy(x: r.minX, y: frame.isFlipped ? frame.bounds.height - r.maxY : r.minY)
            l.render(in: cg)
            cg.restoreGState()
        }
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out + "/" + name + ".png"))
    }
    var steps: [(String, () -> Void)] = [
        ("start", {}),
    ]
    steps = [
        ("1_map", { c.showTab(0) }),
        ("2_select", {
            if let n = c.root?.children.first(where: { $0.isFolder }) { c.select([n], from: nil) }
        }),
        ("3_zoom", { c.zoomIntoSelection() }),
        ("4_types", { c.showTab(1) }),
        ("5_filter", { c.setTypeFilter(category: catVideo, ext: nil, title: "Видео") }),
        ("6_largest", { c.showTab(2) }),
        ("7_up", { c.setTypeFilter(category: nil, ext: nil, title: nil); c.zoomOut() }),
        ("8_age", { Settings.s.colorMode = .age; Settings.s.headers = true }),
    ]
    func next(_ i: Int) {
        guard i < steps.count else {
            Settings.s.colorMode = .category
            Settings.s.headers = false
            c.runDuplicatesForTest {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    shot("9_dups")
                    print("uitest done")
                    NSApp.terminate(nil)
                }
            }
            return
        }
        steps[i].1()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            shot(steps[i].0)
            next(i + 1)
        }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
        func dump(_ v: NSView, _ d: Int) {
            if d > 6 { return }
            print(String(repeating: " ", count: d * 2) + "\(type(of: v)) \(v.frame) hidden=\(v.isHidden)")
            v.subviews.prefix(6).forEach { dump($0, d + 1) }
        }
        if ProcessInfo.processInfo.environment["DUMP"] != nil, let v = c.window?.contentView { dump(v, 0) }
        shot("0_start")
        func findFlipped(_ v: NSView) -> NSView? {
            if v is FlippedView { return v }
            for s in v.subviews { if let f = findFlipped(s) { return f } }
            return nil
        }
        if let v = c.window?.contentView, let f = findFlipped(v), let rep = f.bitmapImageRepForCachingDisplay(in: f.bounds) {
            f.cacheDisplay(in: f.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out + "/0_start_content.png"))
        }
        c.onScanDone { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { next(0) } }
        c.startScan(path)
    }
}

/// Сценарии с изменением дерева на настоящем окне. Работает только с временной папкой, которую создаёт сам.
func runFlowTest(_ d: AppDelegate) {
    let fm = FileManager.default
    let dir = NSTemporaryDirectory() + "diskmap-flow-\(getpid())"
    for f in ["a/x.bin", "a/y.bin", "a/deep/q.bin", "b/z.bin"] {
        try? fm.createDirectory(atPath: (dir + "/" + f as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? Data(repeating: 7, count: 2 << 20).write(to: URL(fileURLWithPath: dir + "/" + f))
    }
    var fails = 0
    func check(_ ok: Bool, _ s: String) { print((ok ? "  ok   " : "  FAIL ") + s); if !ok { fails += 1 } }
    let c = d.makeWindow()
    func wait(_ t: Double = 0.6, _ f: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: f) }
    func child(_ n: FileNode?, _ s: String) -> FileNode? { n?.children.first { $0.name == s } }
    c.onScanDone {
        wait {
            guard let root = c.root, let a = child(root, "a"), let x = child(a, "x.bin"), let deep = child(a, "deep") else {
                print("  FAIL дерево"); exit(1)
            }
            let before = root.alloc
            c.zoom(to: a)
            c.zoom(to: deep)
            c.select([x], from: nil)
            c.performDelete([x], forever: true)
            wait {
                check(!fm.fileExists(atPath: dir + "/a/x.bin"), "файл удалён с диска")
                check(root.alloc == before - (2 << 20) && child(a, "x.bin") == nil, "размер родителей уменьшился")
                check(c.viewRoot === deep, "открытая папка не сменилась")
                check(c.map.layoutData?.tiles.contains { $0.node === x } == false, "плитка исчезла с карты")
                c.select([a], from: nil)
                c.performDelete([a], forever: true)
                wait {
                    check(!fm.fileExists(atPath: dir + "/a"), "папка удалена вместе с открытой внутри")
                    check(c.viewRoot === root, "карта вернулась к ближайшей живой папке")
                    c.goBack(nil); c.goForward(nil)
                    check(c.viewRoot === root, "история не ведёт в удалённое")
                    guard let b = child(root, "b") else { exit(1) }
                    try? Data(repeating: 1, count: 3 << 20).write(to: URL(fileURLWithPath: dir + "/b/new.bin"))
                    let sizeBefore = root.alloc
                    c.select([b], from: nil)
                    c.rescanSelection(nil)
                    wait(1) {
                        check(root.alloc == sizeBefore + (3 << 20), "пересчёт одной папки учёл новый файл")
                        check(child(child(root, "b"), "new.bin") != nil, "новый файл в дереве")
                        c.toggleLogical(nil)
                        wait {
                            check(gUseLogical, "логический режим включён")
                            c.toggleLogical(nil)
                            wait {
                                check(!gUseLogical, "режим занято возвращён")
                                c.select([root], from: nil)
                                c.confirmDeleteForTest()
                                wait {
                                    check(fm.fileExists(atPath: dir + "/b/z.bin"), "корень карты удалить нельзя")
                                    c.window?.attachedSheet.map { c.window?.endSheet($0) }
                                    c.rescan(nil)
                                    wait(1) {
                                        check(c.root !== root && c.root?.alloc == root.alloc, "полный пересчёт дал тот же размер")
                                        try? fm.removeItem(atPath: dir)
                                        print(fails == 0 ? "Сценарии пройдены" : "Ошибок: \(fails)")
                                        exit(fails == 0 ? 0 : 1)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    wait(0.5) { c.startScan(dir) }
}
