import AppKit
import BotAvatar
import SwiftUI

struct AvatarProfileView: View {
    private let live = !CommandLine.arguments.contains("--static")

    var body: some View {
        VStack(spacing: 24) {
            Text(live ? "24 live avatars" : "24 static avatars").font(.headline)
            ForEach(0..<4) { row in
                HStack(spacing: 16) {
                    ForEach(0..<6) { column in
                        let index = row * 6 + column
                        BotAvatarView(
                            seed: "benchmark-\(index)", size: 44,
                            state: [BotState.idle, .working, .sleeping][index % 3], live: live)
                    }
                }
            }
        }
        .task {
            NSApplication.shared.activate()
            let start = Self.cpuSeconds
            try? await Task.sleep(for: .seconds(15))
            print("first_15s_cpu_percent=\((Self.cpuSeconds - start) / 15 * 100)")
            let hide = CommandLine.arguments.contains("--hide")
            if hide { NSApplication.shared.hide(nil) }
            try? await Task.sleep(for: .seconds(2))
            let settled = Self.cpuSeconds
            try? await Task.sleep(for: .seconds(13))
            let cpu = (Self.cpuSeconds - settled) / 13 * 100
            print("last_13s_cpu_percent=\(cpu)")
            if hide, cpu > 5 {
                print("FAIL: hidden avatars are still consuming CPU")
                exit(1)
            }
            NSApplication.shared.terminate(nil)
        }
    }

    private static var cpuSeconds: Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
}
