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

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 440, height: 344))
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
        switch rows[row] {
        case .tier(let name, let count):
            let idxs = groups.indices.filter { groups[$0].tier == name }
            let all = !idxs.isEmpty && idxs.allSatisfy { checked.contains($0) }
            let cb = NSButton(checkboxWithTitle: "\(name)  (\(count))", target: self, action: #selector(toggleTier(_:)))
            cb.font = .boldSystemFont(ofSize: 12)
            cb.state = all ? .on : (idxs.contains { checked.contains($0) } ? .mixed : .off)
            cb.allowsMixedState = true
            cb.tag = row
            return cb
        case .group(let i):
            let g = groups[i]
            // 이미 "못 받는다" 고 확인된 스킬 (스킬 단위 판정)
            // 같은 이름의 ID 하나라도 "못 받음" 이면 그 스킬은 못 받는다 (같은 이미지 파일을 쓴다)
            // ID 전부가 불가일 때만 불가 — 부속 ID 하나가 막혀도 본체는 받아질 수 있다
            let unavailable = g.variants.allSatisfy { MapleWZ.isBadSkill($0.id) }
            let cb = NSButton(checkboxWithTitle: "    \(g.title)"
                              + (installed.contains(g.skill) ? "  ✓" : "")
                              + (unavailable ? "  (받을 수 없음)" : ""),
                              target: self, action: #selector(toggleGroup(_:)))
            cb.state = checked.contains(i) ? .on : .off
            cb.isEnabled = !unavailable
            cb.tag = i
            return cb
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    @objc private func rowClicked() {}

    @objc private func toggleGroup(_ sender: NSButton) {
        if sender.state == .on { checked.insert(sender.tag) } else { checked.remove(sender.tag) }
        table.reloadData()
    }

    @objc private func toggleTier(_ sender: NSButton) {
        guard case .tier(let name, _) = rows[sender.tag] else { return }
        let idxs = groups.indices.filter { groups[$0].tier == name }
        if idxs.allSatisfy({ checked.contains($0) }) { idxs.forEach { checked.remove($0) } }
        else { idxs.forEach { checked.insert($0) } }
        table.reloadData()
    }

    func controlTextDidChange(_ obj: Notification) {
        filter = search.stringValue.trimmingCharacters(in: .whitespaces)
        rebuildRows()
    }
}
