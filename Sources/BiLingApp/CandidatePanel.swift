import AppKit
import BackboneEngine

@MainActor
final class CandidatePanel: NSPanel {
    private let background = NSVisualEffectView()
    private let rootStack = NSStackView()
    private let candidateViewport = NSView()
    private let candidateStack = NSStackView()
    private let modelStatus = NSTextField(labelWithString: "")
    private let pageStatus = NSTextField(labelWithString: "")
    private var onSelect: ((Int) -> Void)?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 58),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        hidesOnDeactivate = false
        isMovable = false

        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 16
        background.layer?.cornerCurve = .continuous
        background.layer?.borderWidth = 0.5
        background.layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
        contentView = background

        candidateStack.orientation = .horizontal
        candidateStack.alignment = .centerY
        candidateStack.spacing = 4
        candidateStack.distribution = .fill
        candidateStack.translatesAutoresizingMaskIntoConstraints = false

        candidateViewport.wantsLayer = true
        candidateViewport.layer?.masksToBounds = true
        candidateViewport.addSubview(candidateStack)
        candidateViewport.setContentHuggingPriority(.defaultLow, for: .horizontal)
        candidateViewport.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            candidateStack.leadingAnchor.constraint(equalTo: candidateViewport.leadingAnchor),
            candidateStack.centerYAnchor.constraint(equalTo: candidateViewport.centerYAnchor),
            candidateStack.topAnchor.constraint(greaterThanOrEqualTo: candidateViewport.topAnchor),
            candidateStack.bottomAnchor.constraint(lessThanOrEqualTo: candidateViewport.bottomAnchor),
        ])

        modelStatus.font = .systemFont(ofSize: 10, weight: .semibold)
        modelStatus.textColor = .secondaryLabelColor
        modelStatus.lineBreakMode = .byTruncatingTail
        modelStatus.setContentCompressionResistancePriority(.required, for: .horizontal)

        pageStatus.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        pageStatus.textColor = .tertiaryLabelColor
        pageStatus.setContentCompressionResistancePriority(.required, for: .horizontal)

        rootStack.orientation = .horizontal
        rootStack.alignment = .centerY
        rootStack.spacing = 10
        rootStack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 12)
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        rootStack.addArrangedSubview(candidateViewport)
        rootStack.addArrangedSubview(pageStatus)
        rootStack.addArrangedSubview(modelStatus)
        background.addSubview(rootStack)

        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            rootStack.topAnchor.constraint(equalTo: background.topAnchor),
            rootStack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            rootStack.heightAnchor.constraint(equalToConstant: 58),
        ])
    }

    func update(
        candidates: [Candidate],
        selected: Int,
        page: Int,
        total: Int,
        modelLatency: Double?,
        modelError: String?,
        onSelect: @escaping (Int) -> Void
    ) {
        self.onSelect = onSelect
        for view in candidateStack.arrangedSubviews {
            candidateStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        for (index, candidate) in candidates.enumerated() {
            let item = CandidateItemControl(
                index: index,
                candidate: candidate,
                isSelected: index == selected
            )
            item.target = self
            item.action = #selector(selectCandidate(_:))
            candidateStack.addArrangedSubview(item)
        }

        let pageCount = max(1, Int(ceil(Double(max(total, 1)) / 9.0)))
        pageStatus.stringValue = pageCount > 1 ? "\(page + 1)/\(pageCount)" : ""
        if let modelError {
            modelStatus.stringValue = "Qwen · 暂不可用"
            modelStatus.textColor = .systemOrange
            modelStatus.toolTip = modelError
        } else if let modelLatency {
            modelStatus.stringValue = "Qwen · \(Int(modelLatency.rounded())) ms"
            modelStatus.textColor = .systemGreen
            modelStatus.toolTip = nil
        } else {
            modelStatus.stringValue = "Qwen · 排序中"
            modelStatus.textColor = .secondaryLabelColor
            modelStatus.toolTip = nil
        }

        candidateStack.layoutSubtreeIfNeeded()
        let candidateWidth = candidateStack.fittingSize.width
        let metadataWidth = pageStatus.intrinsicContentSize.width
            + modelStatus.intrinsicContentSize.width
            + (pageStatus.stringValue.isEmpty ? 10 : 20)
            + 22
        let fittingWidth = candidateWidth + metadataWidth
        setContentSize(
            NSSize(
                width: min(max(fittingWidth, 360), 920),
                height: 58
            )
        )
        background.layoutSubtreeIfNeeded()
        displayIfNeeded()
    }

    func show(relativeTo caret: NSRect) {
        let size = frame.size
        let visible = NSScreen.screens.first(where: { $0.frame.contains(caret.origin) })?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var origin = NSPoint(x: caret.minX, y: caret.minY - size.height - 8)
        if origin.y < visible.minY {
            origin.y = caret.maxY + 8
        }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        setFrameOrigin(origin)
        orderFrontRegardless()
    }

    func dismiss() {
        onSelect = nil
        orderOut(nil)
    }

    func hasRenderableContent(expectedCount: Int) -> Bool {
        background.layoutSubtreeIfNeeded()
        let items = candidateStack.arrangedSubviews.compactMap { $0 as? CandidateItemControl }
        return items.count == expectedCount
            && !items.contains(where: { $0.renderedTitle.isEmpty || $0.frame.width < 1 })
            && frame.width >= 360
            && frame.height == 58
    }

    func writeSnapshot(to url: URL) throws {
        background.layoutSubtreeIfNeeded()
        displayIfNeeded()
        guard let bitmap = background.bitmapImageRepForCachingDisplay(in: background.bounds) else {
            throw CandidatePanelSnapshotError.couldNotCreateBitmap
        }
        background.cacheDisplay(in: background.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw CandidatePanelSnapshotError.couldNotEncodePNG
        }
        try data.write(to: url, options: .atomic)
    }

    @objc private func selectCandidate(_ sender: CandidateItemControl) {
        onSelect?(sender.candidateIndex)
    }
}

@MainActor
private final class CandidateItemControl: NSControl {
    let candidateIndex: Int
    let renderedTitle: String
    private let titleLabel: NSTextField

    init(index: Int, candidate: Candidate, isSelected: Bool) {
        candidateIndex = index
        renderedTitle = "\(index + 1)  \(candidate.text)"
        titleLabel = NSTextField(labelWithString: renderedTitle)
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = isSelected
            ? NSColor.systemIndigo.withAlphaComponent(0.92).cgColor
            : NSColor.clear.cgColor

        let font = NSFont.systemFont(ofSize: 17, weight: isSelected ? .semibold : .regular)
        titleLabel.font = font
        titleLabel.textColor = isSelected ? .white : .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        toolTip = candidate.pinyin
        setAccessibilityRole(.button)
        setAccessibilityLabel(renderedTitle)
        setAccessibilityValue(isSelected ? "已选择" : nil)
        translatesAutoresizingMaskIntoConstraints = false
        setContentCompressionResistancePriority(.required, for: .horizontal)

        let measured = (renderedTitle as NSString).size(
            withAttributes: [.font: font]
        ).width
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 34),
            // AppKit's label metrics can under-report CJK fallback glyph runs.
            // Keep an extra 20-point reserve so complete candidates do not
            // collapse into an ellipsis on mixed Latin/CJK font stacks.
            widthAnchor.constraint(equalToConstant: min(max(measured + 42, 72), 220)),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 11),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -11),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        sendAction(action, to: target)
    }
}

private enum CandidatePanelSnapshotError: Error {
    case couldNotCreateBitmap
    case couldNotEncodePNG
}
