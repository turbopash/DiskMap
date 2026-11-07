import AppKit
import UniformTypeIdentifiers

// MARK: - Общие элементы

func label(_ s: String, size: CGFloat = 12, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
    let t = NSTextField(labelWithString: s)
    t.font = .systemFont(ofSize: size, weight: weight)
    t.textColor = color
    t.lineBreakMode = .byTruncatingMiddle
    t.cell?.truncatesLastVisibleLine = true
    return t
}

private var iconCache: [UInt64: NSImage] = [:]
private let folderIcon = NSWorkspace.shared.icon(for: .folder)
private let appIcon = NSWorkspace.shared.icon(for: .applicationBundle)
private let genericIcon = NSWorkspace.shared.icon(for: .data)

func iconFor(_ n: FileNode) -> NSImage {
    switch n.kind {
    case .dir: return folderIcon
    case .free: return NSImage(systemSymbolName: "circle.dashed", accessibilityDescription: nil) ?? genericIcon
    case .unknown: return NSImage(systemSymbolName: "questionmark.circle", accessibilityDescription: nil) ?? genericIcon
    case .package:
        if extName(n.ext) == "app" { return appIcon }
        return folderIcon
    default: break
    }
    if n.ext == 0 { return genericIcon }
    if let i = iconCache[n.ext] { return i }
    var img = genericIcon
    if let t = UTType(filenameExtension: extName(n.ext)) { img = NSWorkspace.shared.icon(for: t) }
    iconCache[n.ext] = img
    return img
}

final class IconCell: NSTableCellView {
    let icon = NSImageView()
    let text = label("")
    override init(frame: NSRect) {
        super.init(frame: frame)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        text.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon); addSubview(text)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16), icon.heightAnchor.constraint(equalToConstant: 16),
            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
            text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}

final class TextCell: NSTableCellView {
    let text = label("")
    init(right: Bool) {
        super.init(frame: .zero)
        text.alignment = right ? .right : .left
        text.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        text.translatesAutoresizingMaskIntoConstraints = false
        addSubview(text)
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}

final class BarCell: NSView {
    var value = 0.0 { didSet { needsDisplay = true } }
    var color = NSColor.controlAccentColor { didSet { needsDisplay = true } }
    override func draw(_ r: NSRect) {
        let b = bounds.insetBy(dx: 2, dy: 5)
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: b, xRadius: 2, yRadius: 2).fill()
        var f = b; f.size.width = max(1, b.width * CGFloat(min(1, value)))
        color.setFill()
        NSBezierPath(roundedRect: f, xRadius: 2, yRadius: 2).fill()
        let s = fmtPercent(value) as NSString
        let a: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium), .foregroundColor: NSColor.labelColor]
        let z = s.size(withAttributes: a)
        s.draw(at: NSPoint(x: b.maxX - z.width - 3, y: b.midY - z.height / 2), withAttributes: a)
    }
}

func makeColumn(_ id: String, _ title: String, _ width: CGFloat, right: Bool = false, sort: String? = nil, ascending: Bool = false) -> NSTableColumn {
    let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
    c.title = title
    c.width = width
    c.minWidth = 40
    if right { c.headerCell.alignment = .right }
    if let sort { c.sortDescriptorPrototype = NSSortDescriptor(key: sort, ascending: ascending) }
    return c
}

func wrapScroll(_ v: NSView) -> NSScrollView {
    let s = NSScrollView()
    s.documentView = v
    s.hasVerticalScroller = true
    s.hasHorizontalScroller = false
    s.autohidesScrollers = true
    s.borderType = .noBorder
    return s
}

private func cell<T: NSView>(_ tv: NSTableView, _ id: String, _ make: () -> T) -> T {
    let ident = NSUserInterfaceItemIdentifier(id)
    if let v = tv.makeView(withIdentifier: ident, owner: nil) as? T { return v }
    let v = make()
    v.identifier = ident
    return v
}

func nameCell(_ tv: NSTableView, _ n: FileNode) -> NSView {
    let v = cell(tv, "name") { IconCell(frame: .zero) }
    v.icon.image = iconFor(n)
    v.text.stringValue = n.denied ? n.displayName + " (нет доступа)" : n.displayName
    v.text.textColor = n.denied ? .systemOrange : .labelColor
    return v
}

func textCell(_ tv: NSTableView, _ s: String, right: Bool = true) -> NSView {
    let v = cell(tv, right ? "right" : "left") { TextCell(right: right) }
    v.text.stringValue = s
    v.text.lineBreakMode = right ? .byTruncatingTail : .byTruncatingHead
    return v
}

func barCell(_ tv: NSTableView, _ value: Double, _ color: NSColor = .controlAccentColor) -> NSView {
    let v = cell(tv, "bar") { BarCell(frame: .zero) }
    v.value = value
    v.color = color
    return v
}

class NodeOutline: NSOutlineView {
    weak var c: MainController?
    override func keyDown(with e: NSEvent) {
        if e.keyCode == 49 { c?.toggleQuickLook() } else { super.keyDown(with: e) }
    }
    override func menu(for e: NSEvent) -> NSMenu? {
        let r = row(at: convert(e.locationInWindow, from: nil))
        guard r >= 0, item(atRow: r) is FileNode else { return nil }
        if !selectedRowIndexes.contains(r) { selectRowIndexes([r], byExtendingSelection: false) }
        return c?.contextMenu()
    }
}

final class NodeTable: NSTableView {
    weak var c: MainController?
    override func keyDown(with e: NSEvent) {
        if e.keyCode == 49 { c?.toggleQuickLook() } else { super.keyDown(with: e) }
    }
    override func menu(for e: NSEvent) -> NSMenu? {
        let r = row(at: convert(e.locationInWindow, from: nil))
        guard r >= 0 else { return nil }
        if !selectedRowIndexes.contains(r) { selectRowIndexes([r], byExtendingSelection: false) }
        return c?.contextMenu()
    }
}

class Panel: NSView {
    weak var c: MainController?
    /// Панель обновляется, только когда её видно.
    func refresh() {}
    func reveal(_ n: FileNode) {}
}

// MARK: - Дерево

final class TreePanel: Panel, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let outline = NodeOutline()
    private var root: FileNode?
    private var syncing = false
    private var sortKey = "size"
    private var ascending = false
    private var sortedCache: [ObjectIdentifier: [FileNode]] = [:]

    override init(frame: NSRect) {
        super.init(frame: frame)
        outline.addTableColumn(makeColumn("name", "Имя", 180, sort: "name", ascending: true))
        outline.addTableColumn(makeColumn("size", "Размер", 76, right: true, sort: "size"))
        outline.addTableColumn(makeColumn("share", "Доля", 76))
        outline.addTableColumn(makeColumn("count", "Файлов", 62, right: true, sort: "count"))
        outline.addTableColumn(makeColumn("date", "Изменён", 76, right: true, sort: "date"))
        outline.outlineTableColumn = outline.tableColumns[0]
        outline.dataSource = self
        outline.delegate = self
        outline.allowsMultipleSelection = true
        outline.usesAlternatingRowBackgroundColors = true
        outline.style = .plain
        outline.rowHeight = 22
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outline.target = self
        outline.doubleAction = #selector(doubleClicked)
        let s = wrapScroll(outline)
        s.frame = bounds
        s.autoresizingMask = [.width, .height]
        addSubview(s)
    }
    required init?(coder: NSCoder) { fatalError() }

    func setRoot(_ r: FileNode) {
        root = r
        sortedCache = [:]
        outline.c = c
        outline.reloadData()
        outline.expandItem(r)
    }

    override func refresh() {
        sortedCache = [:]
        outline.reloadData()
    }

    private func kids(_ n: FileNode) -> [FileNode] {
        if sortKey == "size" && !ascending { return n.children }
        let id = ObjectIdentifier(n)
        if let k = sortedCache[id] { return k }
        let k: [FileNode]
        switch sortKey {
        case "name": k = n.children.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case "count": k = n.children.sorted { $0.fileCount > $1.fileCount }
        case "date": k = n.children.sorted { $0.mtime > $1.mtime }
        default: k = n.children.sorted { $0.size > $1.size }
        }
        let out = ascending != (sortKey == "name") ? k.reversed() : k
        sortedCache[id] = out
        return out
    }

    func outlineView(_ o: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if let n = item as? FileNode { return kids(n).count }
        return root == nil ? 0 : 1
    }
    func outlineView(_ o: NSOutlineView, child i: Int, ofItem item: Any?) -> Any {
        if let n = item as? FileNode { return kids(n)[i] }
        return root!
    }
    func outlineView(_ o: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as! FileNode).children.isEmpty == false
    }
    func outlineView(_ o: NSOutlineView, viewFor col: NSTableColumn?, item: Any) -> NSView? {
        let n = item as! FileNode
        switch col?.identifier.rawValue {
        case "name": return nameCell(o, n)
        case "size": return textCell(o, fmtSize(n.size))
        case "share": return barCell(o, n.shareOfParent)
        case "count": return textCell(o, n.isFolder ? fmtInt(n.fileCount) : "")
        default: return textCell(o, n.isSynthetic ? "" : fmtDate(n.mtime))
        }
    }
    func outlineView(_ o: NSOutlineView, sortDescriptorsDidChange old: [NSSortDescriptor]) {
        guard let d = o.sortDescriptors.first, let k = d.key else { return }
        sortKey = k
        ascending = d.ascending
        refresh()
    }
    func outlineViewSelectionDidChange(_ n: Notification) {
        guard !syncing else { return }
        let nodes = outline.selectedRowIndexes.compactMap { outline.item(atRow: $0) as? FileNode }
        if !nodes.isEmpty { c?.select(nodes, from: self) }
    }
    @objc private func doubleClicked() {
        guard let n = outline.item(atRow: outline.clickedRow) as? FileNode else { return }
        if n.isFolder { c?.zoom(to: n) } else { c?.toggleQuickLook() }
    }

    override func reveal(_ n: FileNode) {
        guard !n.isSynthetic || n.parent != nil else { return }
        syncing = true
        defer { syncing = false }
        var chain: [FileNode] = []
        var p = n.parent
        while let x = p { chain.append(x); p = x.parent }
        for a in chain.reversed() { outline.expandItem(a) }
        let r = outline.row(forItem: n)
        if r >= 0 {
            outline.selectRowIndexes([r], byExtendingSelection: false)
            outline.scrollRowToVisible(r)
        }
    }
}

// MARK: - Типы файлов

final class TypeRow {
    let title: String, color: NSColor
    var size: Int64 = 0, count = 0
    let cat: Int?, ext: UInt64?
    var kids: [TypeRow] = []
    init(title: String, color: NSColor, cat: Int?, ext: UInt64?) {
        self.title = title; self.color = color; self.cat = cat; self.ext = ext
    }
}

final class SwatchCell: NSTableCellView {
    let dot = NSView()
    let text = label("")
    override init(frame: NSRect) {
        super.init(frame: frame)
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3
        dot.translatesAutoresizingMaskIntoConstraints = false
        text.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dot); addSubview(text)
        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 12), dot.heightAnchor.constraint(equalToConstant: 12),
            text.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 6),
            text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}

final class TypesPanel: Panel, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private let outline = NSOutlineView()
    private var rows: [TypeRow] = []
    private var total: Int64 = 0
    private var job = 0
    private var syncing = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        outline.addTableColumn(makeColumn("name", "Тип", 170))
        outline.addTableColumn(makeColumn("size", "Размер", 80, right: true))
        outline.addTableColumn(makeColumn("share", "Доля", 76))
        outline.addTableColumn(makeColumn("count", "Файлов", 62, right: true))
        outline.outlineTableColumn = outline.tableColumns[0]
        outline.dataSource = self
        outline.delegate = self
        outline.style = .plain
        outline.rowHeight = 22
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        let hint = label("Щёлкни тип: на карте останутся только такие файлы.", size: 11, color: .secondaryLabelColor)
        hint.frame = NSRect(x: 10, y: frame.height - 24, width: frame.width - 20, height: 18)
        hint.autoresizingMask = [.width, .minYMargin]
        addSubview(hint)
        let s = wrapScroll(outline)
        s.frame = NSRect(x: 0, y: 0, width: frame.width, height: frame.height - 28)
        s.autoresizingMask = [.width, .height]
        addSubview(s)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func refresh() {
        guard let root = c?.viewRoot else { return }
        job += 1
        let my = job
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var bySize = [Int64](repeating: 0, count: catCount), byCount = [Int](repeating: 0, count: catCount)
            var exts: [UInt64: (Int64, Int, UInt8)] = [:]
            treeLock.read {
                func walk(_ n: FileNode) {
                    for f in n.children {
                        if f.isFolder { walk(f); continue }
                        if f.isSynthetic { continue }
                        let cat = Int(f.category), sz = f.size
                        bySize[cat] += sz; byCount[cat] += 1
                        let e = exts[f.ext] ?? (0, 0, f.category)
                        exts[f.ext] = (e.0 + sz, e.1 + 1, f.category)
                    }
                }
                walk(root)
            }
            var out: [TypeRow] = []
            for cat in 0...catOther where byCount[cat] > 0 {
                let r = TypeRow(title: catNames[cat], color: nsColor(catColors[cat]), cat: cat, ext: nil)
                r.size = bySize[cat]; r.count = byCount[cat]
                r.kids = exts.filter { Int($0.value.2) == cat }.sorted { $0.value.0 > $1.value.0 }.prefix(60).map {
                    let e = TypeRow(title: $0.key == 0 ? "без расширения" : "." + extName($0.key), color: nsColor($0.key == 0 ? catColors[catOther] : extColor($0.key)), cat: nil, ext: $0.key)
                    e.size = $0.value.0; e.count = $0.value.1
                    return e
                }
                out.append(r)
            }
            out.sort { $0.size > $1.size }
            let sum = bySize.reduce(0, +)
            DispatchQueue.main.async {
                guard let self, my == self.job else { return }
                self.rows = out; self.total = sum
                self.syncing = true
                self.outline.reloadData()
                self.syncing = false
            }
        }
    }

    func outlineView(_ o: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { (item as? TypeRow)?.kids.count ?? rows.count }
    func outlineView(_ o: NSOutlineView, child i: Int, ofItem item: Any?) -> Any { (item as? TypeRow)?.kids[i] ?? rows[i] }
    func outlineView(_ o: NSOutlineView, isItemExpandable item: Any) -> Bool { !(item as! TypeRow).kids.isEmpty }
    func outlineView(_ o: NSOutlineView, viewFor col: NSTableColumn?, item: Any) -> NSView? {
        let r = item as! TypeRow
        let share = total > 0 ? Double(r.size) / Double(total) : 0
        switch col?.identifier.rawValue {
        case "name":
            let v = cell(o, "swatch") { SwatchCell(frame: .zero) }
            v.dot.layer?.backgroundColor = r.color.cgColor
            v.text.stringValue = r.title
            return v
        case "size": return textCell(o, fmtSize(r.size))
        case "share": return barCell(o, share, r.color)
        default: return textCell(o, fmtInt(r.count))
        }
    }
    func outlineViewSelectionDidChange(_ n: Notification) {
        guard !syncing else { return }
        let r = outline.item(atRow: outline.selectedRow) as? TypeRow
        c?.setTypeFilter(category: r?.cat, ext: r?.ext, title: r?.title)
    }
    func clearSelection() {
        syncing = true
        outline.deselectAll(nil)
        syncing = false
    }
}

// MARK: - Самые большие файлы

final class LargestPanel: Panel, NSTableViewDataSource, NSTableViewDelegate {
    private let table = NodeTable()
    private let info = label("", size: 11, color: .secondaryLabelColor)
    private var items: [FileNode] = []
    private var paths: [ObjectIdentifier: String] = [:]
    private var job = 0
    private var syncing = false
    private let limit = 3000

    override init(frame: NSRect) {
        super.init(frame: frame)
        table.addTableColumn(makeColumn("name", "Файл", 170, sort: "name", ascending: true))
        table.addTableColumn(makeColumn("size", "Размер", 76, right: true, sort: "size"))
        table.addTableColumn(makeColumn("date", "Изменён", 76, right: true, sort: "date"))
        table.addTableColumn(makeColumn("path", "Папка", 130))
        table.dataSource = self
        table.delegate = self
        table.allowsMultipleSelection = true
        table.usesAlternatingRowBackgroundColors = true
        table.style = .plain
        table.rowHeight = 22
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.target = self
        table.doubleAction = #selector(open)
        info.frame = NSRect(x: 10, y: frame.height - 24, width: frame.width - 20, height: 18)
        info.autoresizingMask = [.width, .minYMargin]
        addSubview(info)
        let s = wrapScroll(table)
        s.frame = NSRect(x: 0, y: 0, width: frame.width, height: frame.height - 28)
        s.autoresizingMask = [.width, .height]
        addSubview(s)
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func open() { c?.toggleQuickLook() }

    override func refresh() {
        guard let root = c?.viewRoot, let f = c?.filter else { return }
        table.c = c
        job += 1
        let my = job, limit = limit
        let q = f.query
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var found: [FileNode] = []
            var matched = 0
            var bytes: Int64 = 0
            treeLock.read {
                func trim() {
                    found.sort { $0.size > $1.size }
                    found.removeLast(found.count - limit)
                }
                func walk(_ n: FileNode, _ inherited: Bool) {
                    for x in n.children {
                        if x.isSynthetic { continue }
                        let hit = inherited || q.isEmpty || x.name.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                        if x.isFolder { walk(x, hit && !q.isEmpty); continue }
                        guard hit, f.matches(file: x) else { continue }
                        matched += 1; bytes += x.size
                        found.append(x)
                        if found.count > limit * 4 { trim() }
                    }
                }
                walk(root, false)
                found.sort { $0.size > $1.size }
                if found.count > limit { found.removeLast(found.count - limit) }
            }
            DispatchQueue.main.async {
                guard let self, my == self.job else { return }
                self.items = found
                self.paths = [:]
                self.applySort()
                let what = f.isActive ? "Найдено" : "Всего файлов"
                self.info.stringValue = "\(what): \(fmtInt(matched)), \(fmtSize(bytes))" + (matched > found.count ? ". Показаны \(fmtInt(found.count)) самых больших" : "")
            }
        }
    }

    private func applySort() {
        if let d = table.sortDescriptors.first, let k = d.key {
            switch k {
            case "name": items.sort { ($0.name.localizedStandardCompare($1.name) == .orderedAscending) == d.ascending }
            case "date": items.sort { d.ascending ? $0.mtime < $1.mtime : $0.mtime > $1.mtime }
            default: items.sort { d.ascending ? $0.size < $1.size : $0.size > $1.size }
            }
        }
        syncing = true
        table.reloadData()
        syncing = false
    }

    func numberOfRows(in t: NSTableView) -> Int { items.count }
    func tableView(_ t: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        let n = items[row]
        switch col?.identifier.rawValue {
        case "name": return nameCell(t, n)
        case "size": return textCell(t, fmtSize(n.size))
        case "date": return textCell(t, fmtDate(n.mtime))
        default:
            let id = ObjectIdentifier(n)
            let p = paths[id] ?? n.parent?.path ?? ""
            paths[id] = p
            return textCell(t, p, right: false)
        }
    }
    func tableView(_ t: NSTableView, sortDescriptorsDidChange old: [NSSortDescriptor]) { applySort() }
    func tableViewSelectionDidChange(_ n: Notification) {
        guard !syncing else { return }
        let nodes = table.selectedRowIndexes.map { items[$0] }
        if !nodes.isEmpty { c?.select(nodes, from: self) }
    }
}

// MARK: - Дубликаты

final class DuplicatesPanel: Panel, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private let outline = NodeOutline()
    private let info = label("Ищет одинаковые файлы от 1 МБ в открытой папке.", size: 11, color: .secondaryLabelColor)
    private let start = NSButton(title: "Найти", target: nil, action: nil)
    private let markCopies = NSButton(title: "Выбрать копии", target: nil, action: nil)
    private let bar = NSProgressIndicator()
    private var groups: [DupGroup] = []
    private var finder: DuplicateFinder?
    private var syncing = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        outline.addTableColumn(makeColumn("name", "Файл", 180))
        outline.addTableColumn(makeColumn("size", "Размер", 76, right: true))
        outline.addTableColumn(makeColumn("path", "Папка", 190))
        outline.outlineTableColumn = outline.tableColumns[0]
        outline.dataSource = self
        outline.delegate = self
        outline.style = .plain
        outline.rowHeight = 22
        outline.allowsMultipleSelection = true
        outline.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        start.target = self; start.action = #selector(toggle)
        markCopies.target = self; markCopies.action = #selector(selectCopies)
        markCopies.isEnabled = false
        markCopies.toolTip = "Выделяет все файлы в группах, кроме самого старого. Удаляются они только по команде «В Корзину»."
        for b in [start, markCopies] { b.bezelStyle = .rounded; b.controlSize = .small; b.font = .systemFont(ofSize: 11) }
        start.frame = NSRect(x: 8, y: frame.height - 28, width: 70, height: 22)
        markCopies.frame = NSRect(x: 82, y: frame.height - 28, width: 110, height: 22)
        start.autoresizingMask = [.minYMargin]; markCopies.autoresizingMask = [.minYMargin]
        info.frame = NSRect(x: 198, y: frame.height - 26, width: frame.width - 206, height: 18)
        info.autoresizingMask = [.width, .minYMargin]
        bar.style = .bar
        bar.isIndeterminate = false
        bar.maxValue = 1
        bar.controlSize = .small
        bar.isHidden = true
        bar.frame = NSRect(x: 8, y: frame.height - 40, width: frame.width - 16, height: 8)
        bar.autoresizingMask = [.width, .minYMargin]
        [start, markCopies, info, bar].forEach(addSubview)
        let s = wrapScroll(outline)
        s.frame = NSRect(x: 0, y: 0, width: frame.width, height: frame.height - 44)
        s.autoresizingMask = [.width, .height]
        addSubview(s)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// После удаления убирает из результатов то, чего больше нет.
    override func refresh() {
        outline.c = c
        guard let root = c?.root else { return }
        for g in groups { g.files.removeAll { $0.rootNode !== root } }
        groups.removeAll { $0.files.count < 2 }
        syncing = true
        outline.reloadData()
        syncing = false
        if !groups.isEmpty { updateSummary() }
    }

    private func updateSummary() {
        let w = groups.reduce(Int64(0)) { $0 + $1.wasted }
        info.stringValue = "Групп: \(fmtInt(groups.count)), можно освободить \(fmtSize(w))"
    }

    func runForTest(_ done: @escaping () -> Void) { toggle(); testDone = done }
    private var testDone: (() -> Void)?

    @objc private func toggle() {
        if let f = finder { f.cancel(); return }
        guard let root = c?.viewRoot else { return }
        let f = DuplicateFinder()
        finder = f
        groups = []
        outline.reloadData()
        start.title = "Стоп"
        markCopies.isEnabled = false
        bar.isHidden = false
        bar.doubleValue = 0
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let r = f.find(in: root, minSize: 1 << 20) { text, v in
                DispatchQueue.main.async { self?.info.stringValue = text; self?.bar.doubleValue = v }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.finder = nil
                self.start.title = "Найти"
                self.bar.isHidden = true
                if let r {
                    self.groups = r
                    self.outline.reloadData()
                    self.outline.expandItem(nil, expandChildren: true)
                    self.markCopies.isEnabled = !r.isEmpty
                    if r.isEmpty { self.info.stringValue = "Дубликатов нет" } else { self.updateSummary() }
                } else { self.info.stringValue = "Поиск остановлен" }
                self.testDone?()
                self.testDone = nil
            }
        }
    }

    @objc private func selectCopies() {
        var rows = IndexSet()
        for g in groups {
            let keep = g.files.min { $0.mtime < $1.mtime }
            for f in g.files where f !== keep {
                let r = outline.row(forItem: f)
                if r >= 0 { rows.insert(r) }
            }
        }
        outline.selectRowIndexes(rows, byExtendingSelection: false)
        window?.makeFirstResponder(outline)
    }

    func outlineView(_ o: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { (item as? DupGroup)?.files.count ?? (item == nil ? groups.count : 0) }
    func outlineView(_ o: NSOutlineView, child i: Int, ofItem item: Any?) -> Any { (item as? DupGroup)?.files[i] ?? groups[i] }
    func outlineView(_ o: NSOutlineView, isItemExpandable item: Any) -> Bool { item is DupGroup }
    func outlineView(_ o: NSOutlineView, viewFor col: NSTableColumn?, item: Any) -> NSView? {
        if let g = item as? DupGroup {
            switch col?.identifier.rawValue {
            case "name": return textCell(o, "\(g.files.count) копии: \(g.files[0].name)", right: false)
            case "size": return textCell(o, fmtSize(g.wasted))
            default: return textCell(o, "лишнее место", right: false)
            }
        }
        let n = item as! FileNode
        switch col?.identifier.rawValue {
        case "name": return nameCell(o, n)
        case "size": return textCell(o, fmtSize(n.size))
        default: return textCell(o, n.parent?.path ?? "", right: false)
        }
    }
    func outlineViewSelectionDidChange(_ n: Notification) {
        guard !syncing else { return }
        let nodes = outline.selectedRowIndexes.compactMap { outline.item(atRow: $0) as? FileNode }
        if !nodes.isEmpty { c?.select(nodes, from: self) }
    }
}
