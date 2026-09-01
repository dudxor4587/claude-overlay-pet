import AppKit

/// 커스텀 펫 만들기/수정 대화상자.
/// 상태마다 파일(GIF·PNG·낱장 아님, 파일 하나)을 골라 붙인다 — idle 만 필수, 나머지는 선택.
/// 수정 모드에서는 이미 있는 상태를 "유지" 로 보여주고, 클릭하면 교체한다.
final class CustomPetDialog: NSObject {
    static let states: [(key: String, label: String)] = [
        ("idle", "평소 · 서기 (필수)"),
        ("think", "생각 중"),
        ("bash", "명령 실행 중"),
        ("edit", "파일 수정 중"),
        ("done", "작업 완료"),
        ("error", "실패"),
        ("notify", "확인 요청"),
        ("sleep", "세션 종료 · 잠"),
    ]

    private let existing: Set<String>       // 수정 모드: 이미 애니메이션이 있는 상태들
    private var chosen: [String: URL] = [:]
    private var buttons: [String: NSButton] = [:]
    private let nameField = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
    private var okButton: NSButton?

    init(existing: Set<String> = []) { self.existing = existing }

    /// nil = 취소. files 는 이번에 새로 고른 것만 담는다 (유지분은 호출 쪽이 합친다).
    func run(title: String, name: String) -> (name: String, files: [String: URL])? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = existing.isEmpty ? """
        '평소' 하나만 채우면 됩니다. 비워둔 상태는 평소 모습으로 재생됩니다.

        · 사진 1장(JPG·PNG) — 배경을 지우고 8가지 상태 움직임을 자동으로 만듭니다
        · GIF — 그 움직임을 그대로 씁니다 (배경이 있으면 지웁니다)

        배경이 이미 투명한 파일은 손대지 않습니다. 긴 GIF 는 전체에서 16프레임을 고르게 뽑아 씁니다.
        캐릭터가 오른쪽을 보고 있으면 자연스럽습니다.
        """ : """
        이미 있는 상태는 '유지' 로 표시됩니다. 파일을 고른 상태만 교체됩니다.

        · 사진 1장(JPG·PNG) — 배경을 지웁니다. '평소' 에 넣으면 나머지 상태도 그 사진으로
          다시 만들지 물어봅니다
        · GIF — 그 움직임을 그대로 씁니다 (배경이 있으면 지웁니다)

        배경이 이미 투명한 파일은 손대지 않습니다. 긴 GIF 는 전체에서 16프레임을 고르게 뽑아 씁니다.
        """
        let ok = alert.addButton(withTitle: existing.isEmpty ? "만들기" : "저장")
        alert.addButton(withTitle: "취소")
        okButton = ok

        nameField.stringValue = name
        nameField.placeholderString = "펫 이름"
        var rows: [[NSView]] = [[label("이름"), nameField]]
        for (key, text) in Self.states {
            let b = NSButton(title: buttonTitle(key), target: self, action: #selector(pick(_:)))
            b.identifier = NSUserInterfaceItemIdentifier(key)
            b.bezelStyle = .rounded
            buttons[key] = b
            rows.append([label(text), b])
        }
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 6
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).width = 210
        let size = grid.fittingSize
        grid.frame = NSRect(x: 0, y: 0, width: max(size.width, 340), height: size.height)
        alert.accessoryView = grid
        alert.window.initialFirstResponder = nameField
        updateOK()

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let petName = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !petName.isEmpty else { return nil }
        return (petName, chosen)
    }

    private func label(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.alignment = .right
        return l
    }

    private func buttonTitle(_ key: String) -> String {
        if let url = chosen[key] { return url.lastPathComponent }
        if existing.contains(key) { return "유지 (클릭해서 교체)" }
        return "파일 선택…"
    }

    @objc private func pick(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue else { return }
        let panel = NSOpenPanel()
        panel.message = "\(Self.states.first { $0.key == key }?.label ?? key) 애니메이션 (GIF 권장, 투명 배경)"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.gif, .png, .jpeg, .webP]
        if panel.runModal() == .OK, let url = panel.url {
            chosen[key] = url
            sender.title = buttonTitle(key)
        }
        updateOK()
    }

    private func updateOK() {
        okButton?.isEnabled = chosen["idle"] != nil || existing.contains("idle")
    }
}
