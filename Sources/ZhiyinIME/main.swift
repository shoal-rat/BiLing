import AppKit
import InputMethodKit
import OSLog
import ZhiyinCore

// 知音 · Zhiyin — an input method that listens.
//
//   Zhiyin                     run as the input method (launched by the system)
//   Zhiyin --register          register and enable the input source
//   Zhiyin --select            make 知音 the current input source
//   Zhiyin --qintai            open 琴台 (settings) as a normal window
//   Zhiyin --render-panel out.png [paper|night]   draw the panel, for docs
//   Zhiyin --smoke-test        load the score and listener once and exit

let arguments = CommandLine.arguments
let log = Logger(subsystem: "com.zhiyin.inputmethod", category: "lifecycle")
let app = NSApplication.shared

if arguments.contains("--register") {
    let n = InputSource.register(bundle: Bundle.main.bundleURL)
    print("知音 registered (\(n) input source\(n == 1 ? "" : "s") enabled).")
    exit(n > 0 ? 0 : 1)
}
if arguments.contains("--select") {
    exit(InputSource.select(InputSource.modeID) ? 0 : 1)
}
if arguments.contains("--current") {
    print(InputSource.current() ?? "")
    exit(0)
}
if arguments.contains("--disable") {
    InputSource.disable()
    exit(0)
}
if let i = arguments.firstIndex(of: "--render-panel"), i + 1 < arguments.count {
    let scheme: Shanshui.Scheme = arguments.dropFirst(i + 2).first == "night" ? .night : .paper
    let sample = ["吉林大学垃圾学校", "吉林大学", "吉林", "急", "及", "集", "吉"].enumerated().map {
        Candidate(text: $0.element, consumed: $0.offset == 0 ? 21 : 10 - $0.offset, score: 0, voice: .ziqi)
    }
    let ok = MainActor.assumeIsolated {
        StringsPanel.snapshot(.init(candidates: sample, highlighted: 0, page: 0, pageCount: 4, heard: true, listening: false),
                              scheme: scheme, to: URL(fileURLWithPath: arguments[i + 1]))
    }
    exit(ok ? 0 : 1)
}
if arguments.contains("--smoke-test") {
    let ok = MainActor.assumeIsolated { () -> Bool in
        let runtime = Runtime.shared
        guard let qinpu = runtime.qinpu else { print("琴谱 missing"); return false }
        let reader = KeyReader("jilindaxue", syllables: qinpu.syllables)
        guard qinpu.decode(reader).first?.text == "吉林大学" else { print("琴谱 smoke check failed"); return false }
        if let listener = runtime.listener {
            guard let answer = listener.listenNow(context: "", keys: "jilindaxue") else { print("子期 did not answer"); return false }
            print("子期: \(answer.results.first?.text ?? "-") in \(String(format: "%.0f", answer.milliseconds)) ms")
            guard answer.results.first?.text == "吉林大学" else { print("子期 smoke check failed"); return false }
        }
        print("知音 smoke test passed.")
        return true
    }
    exit(ok ? 0 : 70)
}

let connection = Bundle.main.infoDictionary?["InputMethodConnectionName"] as? String ?? "com.zhiyin.inputmethod_Connection"
if arguments.contains("--qintai") {
    app.setActivationPolicy(.accessory)
    MainActor.assumeIsolated { QintaiWindow.shared.show() }
} else {
    app.setActivationPolicy(.prohibited)
}
guard let server = IMKServer(name: connection, bundleIdentifier: Bundle.main.bundleIdentifier) else {
    fatalError("知音 could not start its InputMethodKit server.")
}
log.notice("知音 is listening on \(connection, privacy: .public)")
MainActor.assumeIsolated { _ = Runtime.shared }
withExtendedLifetime(server) { app.run() }
