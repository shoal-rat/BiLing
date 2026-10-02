import AppKit
import SwiftUI
import ZhiyinCore

/// 琴台 · The qin terrace — where 伯牙 met 钟子期 by the Han river, and
/// where you tune 知音. Five rooms: 高山流水 (home), 指法 (touch),
/// 子期 (the listener), 默契 (what has been learned), 山水 (appearance).
@MainActor
final class QintaiWindow {
    static let shared = QintaiWindow()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 760, height: 540),
                styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                backing: .buffered, defer: false
            )
            w.title = "琴台"
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: QintaiView())
            w.center()
            window = w
        }
        NSApp.setActivationPolicy(.accessory)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private enum Room: String, CaseIterable, Identifiable {
    case home = "高山流水", touch = "指法", listener = "子期", rapport = "默契", landscape = "山水"
    var id: String { rawValue }
    var gloss: String {
        switch self {
        case .home: return "知音"
        case .touch: return "按键与标点"
        case .listener: return "本机语言模型"
        case .rapport: return "你的用词习惯"
        case .landscape: return "外观"
        }
    }
    var symbol: String {
        switch self {
        case .home: return "mountain.2"
        case .touch: return "keyboard"
        case .listener: return "ear"
        case .rapport: return "heart.text.square"
        case .landscape: return "paintpalette"
        }
    }
}

private extension Color {
    static let paper = Color(red: 0.965, green: 0.945, blue: 0.906)
    static let ink = Color(red: 0.137, green: 0.149, blue: 0.161)
    static let azurite = Color(red: 0.184, green: 0.396, blue: 0.467)
    static let malachite = Color(red: 0.243, green: 0.541, blue: 0.431)
    static let cinnabar = Color(red: 0.714, green: 0.263, blue: 0.184)
    static let ochre = Color(red: 0.604, green: 0.427, blue: 0.282)
}

struct QintaiView: View {
    @State private var room: Room = .home
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch room {
                    case .home: HomeRoom()
                    case .touch: TouchRoom()
                    case .listener: ListenerRoom()
                    case .rapport: RapportRoom()
                    case .landscape: LandscapeRoom()
                    }
                }
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 760, minHeight: 540)
        .onChange(of: prefs.attentive) { _, _ in Runtime.shared.applyPreferences() }
        .onChange(of: prefs.restAfterMinutes) { _, _ in Runtime.shared.applyPreferences() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("知音")
                .font(.custom("Songti SC", size: 26).weight(.semibold))
                .foregroundStyle(Color.ink)
                .padding(.top, 34)
            Text("ZHIYIN")
                .font(.system(size: 9, weight: .medium)).tracking(3)
                .foregroundStyle(Color.ochre)
                .padding(.bottom, 18)
            ForEach(Room.allCases) { r in
                Button { room = r } label: {
                    HStack(spacing: 10) {
                        Image(systemName: r.symbol).frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(r.rawValue).font(.custom("Songti SC", size: 15))
                            Text(r.gloss).font(.system(size: 10)).opacity(0.6)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 7).padding(.horizontal, 10)
                    .background(RoundedRectangle(cornerRadius: 7).fill(room == r ? Color.azurite.opacity(0.12) : .clear))
                    .foregroundStyle(room == r ? Color.azurite : Color.ink)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Seal(text: "知音").padding(.bottom, 18)
        }
        .padding(.horizontal, 14)
        .frame(width: 190)
        .background(Color.paper)
    }
}

/// A cinnabar seal impression, the signature of every room.
struct Seal: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.custom("Songti SC", size: 12).weight(.bold))
            .foregroundStyle(Color.paper)
            .padding(.horizontal, 6).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 3).fill(Color.cinnabar))
    }
}

/// 青绿山水: layered mountains over water, drawn, not bitmapped.
struct Landscape: View {
    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            ctx.fill(Path(CGRect(origin: .zero, size: size)),
                     with: .linearGradient(Gradient(colors: [Color.paper, Color(red: 0.91, green: 0.93, blue: 0.91)]),
                                           startPoint: .zero, endPoint: CGPoint(x: 0, y: h)))
            ctx.fill(Path(ellipseIn: CGRect(x: w * 0.78, y: h * 0.16, width: 26, height: 26)), with: .color(.cinnabar.opacity(0.85)))
            func ridge(_ base: CGFloat, _ peaks: [(CGFloat, CGFloat)], _ color: Color) {
                var p = Path()
                p.move(to: CGPoint(x: 0, y: h))
                p.addLine(to: CGPoint(x: 0, y: h * base))
                var last = CGPoint(x: 0, y: h * base)
                for (x, y) in peaks {
                    let pt = CGPoint(x: w * x, y: h * y)
                    p.addQuadCurve(to: pt, control: CGPoint(x: (last.x + pt.x) / 2, y: min(last.y, pt.y) - h * 0.04))
                    last = pt
                }
                p.addLine(to: CGPoint(x: w, y: h))
                p.closeSubpath()
                ctx.fill(p, with: .color(color))
            }
            ridge(0.62, [(0.12, 0.42), (0.26, 0.55), (0.42, 0.30), (0.58, 0.50), (0.74, 0.38), (0.9, 0.52), (1, 0.48)], .azurite.opacity(0.22))
            ridge(0.72, [(0.08, 0.58), (0.22, 0.48), (0.36, 0.66), (0.52, 0.52), (0.68, 0.64), (0.84, 0.50), (1, 0.62)], .malachite.opacity(0.38))
            ridge(0.82, [(0.18, 0.70), (0.34, 0.78), (0.50, 0.68), (0.70, 0.80), (0.88, 0.70), (1, 0.76)], .azurite.opacity(0.55))
            // 流水: the water, as strings.
            for i in 0..<5 {
                let y = h * (0.86 + CGFloat(i) * 0.028)
                var line = Path()
                line.move(to: CGPoint(x: w * 0.04, y: y))
                var x = w * 0.04
                while x < w * 0.96 {
                    line.addLine(to: CGPoint(x: x, y: y + sin(x / 18 + CGFloat(i)) * 1.2))
                    x += 4
                }
                ctx.stroke(line, with: .color(.azurite.opacity(0.35 - Double(i) * 0.05)), lineWidth: 0.8)
            }
        }
    }
}

private struct RoomTitle: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.custom("Songti SC", size: 24).weight(.semibold)).foregroundStyle(Color.ink)
            Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }
}

private struct HomeRoom: View {
    @State private var status = Runtime.shared.listenerStatus
    var body: some View {
        Landscape()
            .frame(height: 170)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        VStack(alignment: .leading, spacing: 10) {
            Text("伯牙鼓琴，钟子期听之。")
                .font(.custom("Songti SC", size: 18)).foregroundStyle(Color.ink)
            Text("方鼓琴而志在太山，钟子期曰：“善哉乎鼓琴，巍巍乎若太山。”少选之间而志在流水，钟子期又曰：“善哉乎鼓琴，汤汤乎若流水。”")
                .font(.custom("Songti SC", size: 13)).foregroundStyle(.secondary).lineSpacing(5)
            Text("——《吕氏春秋·本味》").font(.custom("Songti SC", size: 12)).foregroundStyle(Color.ochre)
        }
        Divider()
        VStack(alignment: .leading, spacing: 8) {
            Text("你在键上弹出的只是声音，知音要听出你的意思。")
                .font(.system(size: 13, weight: .medium))
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow { Text("弦").bold(); Text("你按下的键，排在候选窗的弦上") }
                GridRow { Text("子期").bold(); Text("本机微调的语言模型，读前文、听拼音，写出你的意思") }
                GridRow { Text("琴谱").bold(); Text("四十余万词的词库，毫秒内应答，子期休息时独奏") }
                GridRow { Text("默契").bold(); Text("你的选择在本机加密记住，下一次更顺手") }
            }
            .font(.system(size: 12))
            HStack(spacing: 8) {
                Circle().fill(Color.cinnabar).frame(width: 7, height: 7)
                Text(status).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .padding(.top, 6)
        }
        .onAppear { status = Runtime.shared.listenerStatus }
    }
}

private struct TouchRoom: View {
    @ObservedObject private var prefs = Preferences.shared
    var body: some View {
        RoomTitle(title: "指法", subtitle: "按键怎样落在弦上")
        Form {
            Toggle("轻点 Shift 切换中 / 英", isOn: $prefs.shiftToggles)
            Toggle("中文标点（数字之后的 . , : 保持半角）", isOn: $prefs.fullWidthPunctuation)
            Stepper("每页候选：\(prefs.pageSize)", value: $prefs.pageSize, in: 3...9)
        }
        .formStyle(.grouped)
        KeyTable()
    }
}

private struct KeyTable: View {
    let rows: [(String, String)] = [
        ("空格", "选定高亮的候选"), ("1 – 9", "选定对应编号"), ("← →  Tab", "沿弦移动"),
        ("↑ ↓  - =", "翻页"), ("Return", "按原样上屏字母"), ("Esc", "取消"),
        ("'", "分隔音节：xi'an → 西安"), ("Shift", "中 / 英"),
    ]
    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 6) {
            ForEach(rows, id: \.0) { row in
                GridRow {
                    Text(row.0).font(.system(size: 12, design: .monospaced)).foregroundStyle(Color.azurite)
                    Text(row.1).font(.system(size: 12))
                }
            }
        }
        .padding(.horizontal, 6)
    }
}

private struct ListenerRoom: View {
    @ObservedObject private var prefs = Preferences.shared
    @State private var status = Runtime.shared.listenerStatus
    var body: some View {
        RoomTitle(title: "子期", subtitle: "在这台 Mac 上运行的拼音语言模型，不联网，不上传")
        HStack(spacing: 8) {
            Circle().fill(Color.cinnabar).frame(width: 7, height: 7)
            Text(status).font(.system(size: 12))
        }
        Form {
            Toggle("请子期来听（关闭则琴谱独奏）", isOn: $prefs.listenerEnabled)
            Picker("听法", selection: $prefs.attentive) {
                Text("细听 · 束宽 4").tag(true)
                Text("轻听 · 束宽 2，更省电").tag(false)
            }
            .pickerStyle(.segmented)
            Toggle("读光标前的文字作为前文", isOn: $prefs.readContext)
            Toggle("低电量模式下独奏，不唤醒子期", isOn: $prefs.soloOnLowPower)
            Stepper("闲置 \(prefs.restAfterMinutes) 分钟后子期小憩（释放内存）", value: $prefs.restAfterMinutes, in: 1...120)
        }
        .formStyle(.grouped)
        Text("子期只在你按键时工作：每个按键一次约 5–8 步解码，新按键会立即打断旧的搜索。没有任何定时轮询；小憩后，下一个按键会把它唤醒。")
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .onAppear { status = Runtime.shared.listenerStatus }
    }
}

private struct RapportRoom: View {
    @State private var memories: [Moqi.Memory] = Runtime.shared.moqi.all
    @State private var filter = ""
    @ObservedObject private var prefs = Preferences.shared
    var body: some View {
        RoomTitle(title: "默契", subtitle: "\(memories.count) 条记忆，AES-GCM 加密，密钥在钥匙串，不进 Time Machine")
        Toggle("从我的选择中学习", isOn: $prefs.learning)
        HStack {
            TextField("搜索", text: $filter).textFieldStyle(.roundedBorder).frame(width: 220)
            Spacer()
            Button("导出…") { export() }
            Button("全部忘记", role: .destructive) {
                Runtime.shared.moqi.forgetAll()
                memories = []
            }
        }
        List {
            ForEach(memories.filter { filter.isEmpty || $0.text.contains(filter) || $0.keys.contains(filter) }, id: \.self) { m in
                HStack {
                    Text(m.text).font(.system(size: 14))
                    Text(m.keys).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%.1f", m.strength)).font(.system(size: 11)).foregroundStyle(Color.ochre)
                    Button {
                        Runtime.shared.moqi.forget(keys: m.keys, text: m.text)
                        memories = Runtime.shared.moqi.all
                    } label: { Image(systemName: "xmark.circle") }
                    .buttonStyle(.borderless)
                }
            }
        }
        .frame(minHeight: 260)
        Text("以下情形从不学习：密码框（Secure Input）、网址与邮箱、长数字、按 Return 原样上屏的字母。")
            .font(.system(size: 11)).foregroundStyle(.secondary)
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "知音-默契.json"
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Runtime.shared.moqi.export() else { return }
        try? data.write(to: url)
    }
}

private struct LandscapeRoom: View {
    @ObservedObject private var prefs = Preferences.shared
    var body: some View {
        RoomTitle(title: "山水", subtitle: "候选窗的纸、墨与字")
        Form {
            Picker("纸色", selection: $prefs.scheme) {
                ForEach(Shanshui.Scheme.allCases) { Text($0.rawValue).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            Picker("字体", selection: $prefs.typeface) {
                ForEach(Shanshui.Typeface.allCases) { Text($0.rawValue).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            Slider(value: $prefs.fontSize, in: 13...24, step: 1) { Text("字号 \(Int(prefs.fontSize))") }
        }
        .formStyle(.grouped)
        PanelPreview(scheme: prefs.schemeValue, typeface: prefs.typefaceValue, size: prefs.fontSize)
            .frame(height: 70)
    }
}

private struct PanelPreview: NSViewRepresentable {
    let scheme: Shanshui.Scheme
    let typeface: Shanshui.Typeface
    let size: Double

    func makeNSView(context: Context) -> NSView {
        let host = NSView()
        let view = StringsView(frame: .zero)
        host.addSubview(view)
        return host
    }

    func updateNSView(_ host: NSView, context: Context) {
        guard let view = host.subviews.first as? StringsView else { return }
        view.content = .init(
            candidates: ["吉林大学", "吉林", "急", "及", "集"].enumerated().map {
                Candidate(text: $0.element, consumed: $0.offset == 0 ? 10 : 5 - $0.offset, score: 0, voice: .ziqi)
            },
            highlighted: 0, page: 0, pageCount: 3, heard: true, listening: false
        )
        view.colors = Shanshui.colors(for: scheme, appearance: host.effectiveAppearance)
        view.typeface = typeface
        view.fontSize = CGFloat(size)
        let fit = view.fittingSize
        view.frame = NSRect(x: 8, y: 8, width: fit.width, height: fit.height)
        view.needsDisplay = true
    }
}
