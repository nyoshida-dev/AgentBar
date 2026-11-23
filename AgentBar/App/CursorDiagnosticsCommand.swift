import Foundation
import AgentBarKit

/// `AgentBar --cursor-diagnostics` prints a redacted trace and exits before the menu bar
/// app starts. The same binary the owner installed, so no Xcode is required.
enum CursorDiagnosticsCommand {
    nonisolated static func runIfRequested() {
        guard CommandLine.arguments.contains("--cursor-diagnostics") else { return }
        let ready = DispatchSemaphore(value: 0)
        Task.detached {
            let text = await CursorDiagnostics.report()
            print(text)
            ready.signal()
        }
        ready.wait()
        exit(0)
    }
}
