import AppKit
import BackboneEngine

@MainActor
final class PreferencesWindowController: NSWindowController {
    static let shared = PreferencesWindowController()
    private let runtime = Runtime.shared
    private let contentStack = NSStackView()
    private let statusLabel = NSTextField(labelWithString: "正在连接…")
    private let statusDot = NSView()
    private let learningSummary = NSTextField(wrappingLabelWithString: "")
    private var sidebarButtons: [NSButton] = []
    private var sectionViews: [Int: NSView] = [:]

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "笔灵"
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 720, height: 520)
        super.init(window: window)
        window.center()
        buildUI()
    }

    required init?(coder: NSCoder) { nil }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        runtime.llm.refreshStatus { [weak self] in self?.refreshStatus() }
        refreshStatus()
    }

    private func buildUI() {
        guard let root = window?.contentView else { return }
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let sidebar = NSVisualEffectView()
        sidebar.material = .sidebar
        sidebar.blendingMode = .behindWindow
        sidebar.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView()
        icon.image = NSImage(named: "AppIcon")
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(icon)

        let title = NSTextField(labelWithString: "笔灵")
        title.font = .systemFont(ofSize: 25, weight: .bold)
        title.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(title)

        let subtitle = NSTextField(labelWithString: "本地 AI 拼音输入法")
        subtitle.textColor = .secondaryLabelColor
        subtitle.font = .systemFont(ofSize: 12, weight: .medium)
        subtitle.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(subtitle)

        let tabs = NSStackView()
        tabs.orientation = .vertical
        tabs.spacing = 7
        tabs.alignment = .leading
        tabs.translatesAutoresizingMaskIntoConstraints = false
        for (index, item) in [
            ("sparkles", "概览"),
            ("keyboard", "输入"),
            ("brain.head.profile", "学习与隐私"),
            ("info.circle", "关于"),
        ].enumerated() {
            let (symbol, label) = item
            let button = NSButton(title: label, target: nil, action: nil)
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            button.imagePosition = .imageLeading
            button.bezelStyle = label == "概览" ? .recessed : .inline
            button.font = .systemFont(ofSize: 14, weight: label == "概览" ? .semibold : .regular)
            button.tag = index
            button.target = self
            button.action = #selector(selectSection(_:))
            sidebarButtons.append(button)
            tabs.addArrangedSubview(button)
        }
        sidebar.addSubview(tabs)

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 18
        contentStack.edgeInsets = NSEdgeInsets(top: 42, left: 38, bottom: 38, right: 38)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        let document = NSView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(contentStack)
        scroll.documentView = document

        root.addSubview(sidebar)
        root.addSubview(scroll)
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: root.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 218),
            icon.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 24),
            icon.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 38),
            icon.widthAnchor.constraint(equalToConstant: 58),
            icon.heightAnchor.constraint(equalToConstant: 58),
            title.leadingAnchor.constraint(equalTo: icon.leadingAnchor),
            title.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 12),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
            tabs.leadingAnchor.constraint(equalTo: icon.leadingAnchor),
            tabs.trailingAnchor.constraint(lessThanOrEqualTo: sidebar.trailingAnchor, constant: -16),
            tabs.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 34),
            scroll.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            contentStack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: document.topAnchor),
            contentStack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])

        let heading = NSTextField(labelWithString: "输入更懂你，数据只属于你")
        heading.font = .systemFont(ofSize: 28, weight: .bold)
        contentStack.addArrangedSubview(heading)
        sectionViews[0] = heading

        let description = wrappingLabel("Qwen 在本机理解上下文并重新排序完整候选集。所有推理与学习数据都留在这台 Mac 上。")
        description.textColor = .secondaryLabelColor
        contentStack.addArrangedSubview(description)

        contentStack.addArrangedSubview(statusCard())
        let settings = settingsCard()
        contentStack.addArrangedSubview(settings)
        sectionViews[1] = settings
        let privacy = privacyCard()
        contentStack.addArrangedSubview(privacy)
        sectionViews[2] = privacy
        let about = aboutCard()
        contentStack.addArrangedSubview(about)
        sectionViews[3] = about
        for view in contentStack.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -76).isActive = true
        }
    }

    @objc private func selectSection(_ sender: NSButton) {
        guard let section = sectionViews[sender.tag] else { return }
        for button in sidebarButtons {
            let selected = button === sender
            button.bezelStyle = selected ? .recessed : .inline
            button.font = .systemFont(
                ofSize: 14,
                weight: selected ? .semibold : .regular
            )
        }
        section.scrollToVisible(section.bounds)
    }

    private func statusCard() -> NSView {
        let card = cardView()
        let stack = verticalStack()
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        card.addSubview(stack)
        pin(stack, to: card)

        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 9
        row.alignment = .centerY
        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 5
        statusDot.translatesAutoresizingMaskIntoConstraints = false
        statusDot.widthAnchor.constraint(equalToConstant: 10).isActive = true
        statusDot.heightAnchor.constraint(equalToConstant: 10).isActive = true
        let title = NSTextField(labelWithString: "Qwen 推理引擎")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        row.addArrangedSubview(statusDot)
        row.addArrangedSubview(title)
        row.addArrangedSubview(NSView())
        let badge = NSTextField(labelWithString: "本地 · Metal")
        badge.textColor = .secondaryLabelColor
        badge.font = .systemFont(ofSize: 11, weight: .medium)
        row.addArrangedSubview(badge)
        stack.addArrangedSubview(row)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        statusLabel.lineBreakMode = .byTruncatingMiddle
        stack.addArrangedSubview(statusLabel)
        refreshStatus()
        return card
    }

    private func settingsCard() -> NSView {
        let card = cardView()
        let stack = verticalStack()
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 20, bottom: 10, right: 14)
        card.addSubview(stack)
        pin(stack, to: card)
        stack.addArrangedSubview(toggleRow("中英边界自动空格", detail: "中文与 Latin 文本相邻时自动补空格", keyPath: \.autoSpacing))
        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(toggleRow("中文标点", detail: "中文语境使用全角标点", keyPath: \.fullWidthPunctuation))
        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(toggleRow("即时学习", detail: "选择一次，下一次立即调整排序", keyPath: \.learningEnabled))
        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(toggleRow(
            "模糊拼音与打字纠错",
            detail: "z/zh、n/l、an/ang 等模糊音，并容忍一次打字失误",
            keyPath: \.fuzzyPinyin
        ))
        return card
    }

    private func privacyCard() -> NSView {
        let card = cardView()
        let stack = verticalStack()
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        card.addSubview(stack)
        pin(stack, to: card)
        let title = NSTextField(labelWithString: "学习与隐私")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        stack.addArrangedSubview(title)
        learningSummary.textColor = .secondaryLabelColor
        refreshLearningSummary()
        stack.addArrangedSubview(learningSummary)
        let review = NSButton(title: "查看与清除所学内容…", target: self, action: #selector(reviewLearning))
        review.bezelStyle = .rounded
        review.controlSize = .large
        stack.addArrangedSubview(review)
        return card
    }

    private func aboutCard() -> NSView {
        let card = cardView()
        let stack = verticalStack()
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        card.addSubview(stack)
        pin(stack, to: card)

        let title = NSTextField(labelWithString: "关于笔灵")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        stack.addArrangedSubview(title)

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "开发版本"
        let details = wrappingLabel(
            "版本 \(version) · Qwen3-0.6B-Base Q4_K_M · 1,440,094 条词汇\n"
                + "模型与 Rime pinyin-simp 使用 Apache-2.0；万象主词库使用 CC BY 4.0。"
        )
        details.textColor = .secondaryLabelColor
        stack.addArrangedSubview(details)

        let licenses = NSButton(
            title: "查看第三方许可证…",
            target: self,
            action: #selector(openLicenses)
        )
        licenses.bezelStyle = .rounded
        stack.addArrangedSubview(licenses)
        return card
    }

    @objc private func openLicenses() {
        guard let resources = Bundle.main.resourceURL else { return }
        NSWorkspace.shared.open(resources.appendingPathComponent("Licenses"))
    }

    @objc private func reviewLearning() {
        let items = runtime.engine.learningStore.learnedItems()
        let alert = NSAlert()
        alert.messageText = items.isEmpty ? "笔灵还没有学习记录" : "笔灵学到的本地偏好"
        if items.isEmpty {
            alert.informativeText = "当你选择候选时，符合隐私规则的词频会显示在这里。"
            alert.addButton(withTitle: "完成")
            alert.runModal()
            return
        }

        let visible = items.prefix(40).map {
            "\($0.pinyin)  →  \($0.text)    ×\($0.count)    \($0.lastSelected.formatted(date: .abbreviated, time: .shortened))"
        }
        let remainder = items.count > visible.count ? "\n…另有 \(items.count - visible.count) 条" : ""
        alert.informativeText = visible.joined(separator: "\n") + remainder
        alert.addButton(withTitle: "清除全部…")
        alert.addButton(withTitle: "完成")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        confirmResetLearning()
    }

    private func confirmResetLearning() {
        let alert = NSAlert()
        alert.messageText = "清除笔灵学到的全部内容？"
        alert.informativeText = "加密的个人词频与选择记录会被永久删除。系统词典和 Qwen 模型不会受到影响。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "清除")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        runtime.engine.learningStore.reset()
        refreshLearningSummary()
    }

    private func refreshLearningSummary() {
        let count = runtime.engine.learningStore.learnedItems().count
        learningSummary.stringValue = "已学习 \(count) 条本地偏好。内容使用 Keychain 密钥加密，存储目录已排除系统备份，工程不包含网络权限。"
    }

    private func refreshStatus() {
        statusDot.layer?.backgroundColor = runtime.llm.isReady
            ? NSColor.systemGreen.cgColor
            : NSColor.systemOrange.cgColor
        statusLabel.stringValue = runtime.llm.statusText
    }

    private func toggleRow(
        _ title: String,
        detail: String,
        keyPath: ReferenceWritableKeyPath<AppSettings, Bool>
    ) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        let labels = verticalStack()
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 14, weight: .medium)
        let subheading = NSTextField(labelWithString: detail)
        subheading.font = .systemFont(ofSize: 11)
        subheading.textColor = .secondaryLabelColor
        labels.addArrangedSubview(heading)
        labels.addArrangedSubview(subheading)
        row.addArrangedSubview(labels)
        row.addArrangedSubview(NSView())
        let toggle = NSSwitch()
        toggle.state = AppSettings.shared[keyPath: keyPath] ? .on : .off
        toggle.target = ClosureSleeve.shared
        let identifier = NSUserInterfaceItemIdentifier(UUID().uuidString)
        toggle.identifier = identifier
        ClosureSleeve.shared.actions[identifier.rawValue] = { sender in
            guard let sender = sender as? NSSwitch else { return }
            AppSettings.shared[keyPath: keyPath] = sender.state == .on
        }
        toggle.action = #selector(ClosureSleeve.invoke(_:))
        row.addArrangedSubview(toggle)
        return row
    }

    private func cardView() -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.72).cgColor
        view.layer?.cornerRadius = 14
        view.layer?.cornerCurve = .continuous
        view.layer?.borderWidth = 0.5
        view.layer?.borderColor = NSColor.separatorColor.cgColor
        return view
    }

    private func verticalStack() -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func wrappingLabel(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.maximumNumberOfLines = 0
        return label
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    private func pin(_ view: NSView, to parent: NSView) {
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            view.topAnchor.constraint(equalTo: parent.topAnchor),
            view.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
        ])
    }
}

@MainActor
private final class ClosureSleeve: NSObject {
    static let shared = ClosureSleeve()
    var actions: [String: (Any?) -> Void] = [:]

    @objc func invoke(_ sender: Any?) {
        guard let control = sender as? NSControl, let identifier = control.identifier?.rawValue else { return }
        actions[identifier]?(sender)
    }
}
