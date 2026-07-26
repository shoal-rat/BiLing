import AppKit
import Darwin
import InputMethodKit
import OSLog

private let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.biling.inputmethod.BiLing"
private let isSmokeTest = CommandLine.arguments.contains("--smoke-test")
private let isEngineStatusTest = CommandLine.arguments.contains("--engine-status-test")
private let snapshotArgumentIndex = CommandLine.arguments.firstIndex(of: "--render-candidate-panel")
private let snapshotPath = snapshotArgumentIndex.flatMap { index in
    CommandLine.arguments.indices.contains(index + 1) ? CommandLine.arguments[index + 1] : nil
}
private let isDiagnosticRun = isSmokeTest || isEngineStatusTest || snapshotPath != nil
private let connectionName = isDiagnosticRun
    ? "\(bundleIdentifier)_Smoke_\(ProcessInfo.processInfo.processIdentifier)"
    : "\(bundleIdentifier)_Connection"
private let app = NSApplication.shared
private let logger = Logger(subsystem: bundleIdentifier, category: "lifecycle")

if CommandLine.arguments.contains("--current-input-source") {
    if let identifier = InputSourceRegistration.currentIdentifier() {
        print(identifier)
        exit(0)
    }
    exit(1)
}

if let selectIndex = CommandLine.arguments.firstIndex(of: "--select-input-source"),
   CommandLine.arguments.indices.contains(selectIndex + 1) {
    exit(
        InputSourceRegistration.select(
            identifier: CommandLine.arguments[selectIndex + 1]
        ) ? 0 : 1
    )
}

if CommandLine.arguments.contains("--register-input-source") {
    do {
        let count = try InputSourceRegistration.register(bundleURL: Bundle.main.bundleURL)
        print("Registered and enabled 笔灵 as a non-Latin Simplified Chinese source (\(count) sources).")
        exit(0)
    } catch {
        fputs("\(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

if CommandLine.arguments.contains("--preferences") {
    app.setActivationPolicy(.accessory)
    MainActor.assumeIsolated {
        PreferencesWindowController.shared.showWindow(nil)
        app.activate(ignoringOtherApps: true)
    }
} else {
    app.setActivationPolicy(.prohibited)
}

logger.notice("Starting InputMethodKit server with bundle metadata")
guard let server = IMKServer(name: connectionName, bundleIdentifier: bundleIdentifier) else {
    fatalError("Could not start the BiLing IMKit server.")
}
logger.notice("InputMethodKit server is ready")

if let snapshotPath {
    Task { @MainActor in
        let result = InputControllerSmokeTest.renderCandidatePanel(
            to: URL(fileURLWithPath: snapshotPath)
        )
        if result.succeeded {
            logger.notice("\(result.message, privacy: .public)")
            app.terminate(nil)
        } else {
            logger.fault("\(result.message, privacy: .public)")
            fputs("BiLing panel render failed: \(result.message)\n", stderr)
            exit(70)
        }
    }
} else if isSmokeTest {
    Task { @MainActor in
        let result = InputControllerSmokeTest.run()
        if result.succeeded {
            logger.notice("\(result.message, privacy: .public)")
            app.terminate(nil)
        } else {
            logger.fault("\(result.message, privacy: .public)")
            fputs("BiLing controller smoke test failed: \(result.message)\n", stderr)
            exit(70)
        }
    }
} else if isEngineStatusTest {
    Task { @MainActor in
        let client = EngineClient.shared
        for _ in 0..<30 {
            await withCheckedContinuation { continuation in
                client.refreshStatus {
                    continuation.resume()
                }
            }
            if client.isReady {
                logger.notice("Installed-app Qwen health check passed")
                app.terminate(nil)
                return
            }
            try? await Task.sleep(for: .seconds(1))
        }
        logger.fault("Installed-app Qwen health check timed out")
        fputs("BiLing could not reach the Qwen service after 30 seconds.\n", stderr)
        exit(70)
    }
}
withExtendedLifetime(server) {
    app.run()
}
