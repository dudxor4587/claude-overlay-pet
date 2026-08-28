import AppKit

/// 스킬 선택 다이얼로그: 검색 + 차수 헤더(전체 토글) + 스킬 체크박스.
/// 스킬은 변형(Effect/Hit…)을 묶은 단위로 보여주고, 고르면 변형을 전부 받는다.
@MainActor
final class SkillPicker: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    struct Group { let tier: String; let tierOrder: Int; let skill: String; let title: String; let variants: [MapleWZ.Skill] }
    private enum Row { case tier(String, Int); case group(Int) }

    private let groups: [Group]
    private var checked: Set<Int> = []
    private var rows: [Row] = []
    private var filter = ""
    private let table = NSTableView()
    private let search = NSSearchField()
    private let installed: Set<String>
    /// 그릴 때마다 다시 세지 않으려고 미리 잡아둔다 (스크롤 중에는 바뀌지 않는 값들)
    private var unavailable: [Bool] = []
    private var tierIndexes: [String: [Int]] = [:]

    private static let cellID = NSUserInterfaceItemIdentifier("skillRow")
    private static let bold = NSFont.boldSystemFont(ofSize: 12)
    private static let plain = NSFont.systemFont(ofSize: 12)

    init(skills: [MapleWZ.Skill]) {
        var map: [String: [MapleWZ.Skill]] = [:]
        var order: [String] = []
        for s in skills {
            let key = "\(s.tierOrder)|\(s.tier)|\(s.name)"
            if map[key] == nil { order.append(key) }
            map[key, default: []].append(s)
        }
        groups = order.map { key in
            let vs = map[key]!, f = vs[0]
            return Group(tier: f.tier, tierOrder: f.tierOrder, skill: f.name, title: f.name, variants: vs)
        }.sorted { ($0.tierOrder, $0.title) < ($1.tierOrder, $1.title) }
        installed = Set(EffectInfo.all().map(\.skill))
        super.init()
        // 같은 이름의 ID 가 전부 불가일 때만 불가 — 부속 ID 하나가 막혀도 본체는 받아질 수 있다
        unavailable = groups.map { g in g.variants.allSatisfy { MapleWZ.isBadSkill($0.id) } }
        for (i, g) in groups.enumerated() { tierIndexes[g.tier, default: []].append(i) }
        rebuildRows()
    }

    private func rebuildRows() {
        rows = []
        var lastTier = ""
        for (i, g) in groups.enumerated() {
            if !filter.isEmpty, !g.title.lowercased().contains(filter.lowercased()) { continue }
            if g.tier != lastTier {
                lastTier = g.tier
                let count = groups.filter { $0.tier == g.tier && (filter.isEmpty || $0.title.lowercased().contains(filter.lowercased())) }.count
                rows.append(.tier(g.tier, count))
            }
            rows.append(.group(i))
        }
        table.reloadData()
    }

    /// 선택된 스킬(변형 포함). 취소면 nil.
    func run(title: String) -> [MapleWZ.Skill]? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "받을 스킬을 체크하세요. 차수 줄을 누르면 그 차수 전체가 토글됩니다."
        alert.addButton(withTitle: "받기"); alert.addButton(withTitle: "취소")

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 380))
        search.frame = NSRect(x: 0, y: 352, width: 440, height: 26)
        search.placeholderString = "스킬 검색"
        search.delegate = self
        container.addSubview(search)

        let scroll = MainThreadScrollView(frame: NSRect(x: 0, y: 0, width: 440, height: 344))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let col = NSTableColumn(identifier: .init("c")); col.width = 420
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = 22
        table.dataSource = self; table.delegate = self
        table.target = self; table.action = #selector(rowClicked)
        scroll.documentView = table
        container.addSubview(scroll)
        alert.accessoryView = container
        alert.window.initialFirstResponder = search

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        // NSTableView 의 dataSource/delegate 는 약한 참조가 아니다.
        // 이 객체가 먼저 해제되면 이후 이벤트에서 사라진 주소를 불러 크래시가 난다.
        table.dataSource = nil
        table.delegate = nil
        table.target = nil
        search.delegate = nil
        guard response == .alertFirstButtonReturn else { return nil }
        return checked.sorted().flatMap { groups[$0].variants }
    }

    // MARK: table
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        // 체크박스는 하나 만드는 데 1.6ms 든다. 줄마다 새로 만들면 한 화면(16줄)에 25ms 라
        // 60fps 예산(16.7ms)을 넘겨 스크롤이 멈춘다 — 재사용 큐에서 꺼내 내용만 바꾼다.
        let cb: NSButton
        if let reused = tableView.makeView(withIdentifier: Self.cellID, owner: self) as? NSButton {
            cb = reused
        } else {
            cb = NSButton(checkboxWithTitle: "", target: self, action: #selector(rowToggled(_:)))
            cb.identifier = Self.cellID
        }
        cb.tag = row
        switch rows[row] {
        case .tier(let name, let count):
            let idxs = tierIndexes[name] ?? []
            cb.title = "\(name)  (\(count))"
            cb.font = Self.bold
            cb.allowsMixedState = true
            cb.isEnabled = true
            cb.state = !idxs.isEmpty && idxs.allSatisfy(checked.contains) ? .on
                     : (idxs.contains(where: checked.contains) ? .mixed : .off)
        case .group(let i):
            let g = groups[i]
            cb.title = "    \(g.title)"
                + (installed.contains(g.skill) ? "  ✓" : "")
                + (unavailable[i] ? "  (받을 수 없음)" : "")
            cb.font = Self.plain
            cb.allowsMixedState = false
            cb.isEnabled = !unavailable[i]
            cb.state = checked.contains(i) ? .on : .off
        }
        return cb
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    @objc private func rowClicked() {}

    /// 체크박스를 재사용하므로 액션도 하나다. 어느 줄인지는 tag(행 번호)로 되짚는다.
    @objc private func rowToggled(_ sender: NSButton) {
        guard rows.indices.contains(sender.tag) else { return }
        switch rows[sender.tag] {
        case .tier(let name, _):
            let idxs = tierIndexes[name] ?? []
            if idxs.allSatisfy(checked.contains) { idxs.forEach { checked.remove($0) } }
            else { idxs.forEach { checked.insert($0) } }
        case .group(let i):
            if checked.contains(i) { checked.remove(i) } else { checked.insert(i) }
        }
        table.reloadData()
    }

    func controlTextDidChange(_ obj: Notification) {
        filter = search.stringValue.trimmingCharacters(in: .whitespaces)
        rebuildRows()
    }
}

/// 휠 스크롤을 AppKit 의 concurrent(responsive) 경로가 아니라 메인 스레드에서 처리하게 한다.
///
/// 이 앱은 클릭 통과 판정을 위해 전역·로컬 NSEvent 모니터를 걸어 둔다. 그 상태에서 AppKit 이
/// 휠 이벤트마다 자기 스크롤 모니터를 등록하려 하면(`_NSScrollingConcurrentEventMonitor
/// startMonitoring` → `_addConcurrentEventMonitorMatchingMask:`) 같은 모니터 레지스트리 락에서
/// 부딪혀 한 번에 700ms 가까이 멈춘다. 휠을 굴려도 화면이 굳어 있다가 뒤늦게 툭 내려간다.
///
/// `scrollWheel(with:)` 을 재정의하면 AppKit 이 이 스크롤뷰를 responsive scrolling 대상에서
/// 빼고 예전 경로로 처리한다. 목록은 한 화면 그리는 데 7ms 라 메인 스레드로도 60fps 가 나온다.
/// 계측값: 휠→화면 지연 중앙 732ms → 1ms.
final class MainThreadScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) { super.scrollWheel(with: event) }
}
