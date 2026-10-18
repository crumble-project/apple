import BotAvatar
import Foundation
import SwiftUI

@MainActor
enum AvatarBenchmark {
    static func run(frames: Int, size: Double) {
        let renderer = ImageRenderer(content: AvatarBenchmarkFrame(time: 0, size: size))
        renderer.scale = 2
        for frame in 0..<10 {
            autoreleasepool {
                renderer.content = AvatarBenchmarkFrame(time: Double(frame) / 30, size: size)
                _ = renderer.cgImage
            }
        }
        let start = ContinuousClock.now
        var rendered = 0
        for frame in 0..<frames {
            autoreleasepool {
                renderer.content = AvatarBenchmarkFrame(time: Double(frame + 10) / 30, size: size)
                if renderer.cgImage != nil { rendered += 1 }
            }
        }
        let elapsed = start.duration(to: .now)
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        print("avatars=24 size=\(Int(size)) frames=\(rendered) seconds=\(seconds)")
        print("milliseconds_per_frame=\(seconds * 1000 / Double(max(1, rendered)))")
        if rendered != frames { exit(1) }
    }
}

private struct AvatarBenchmarkFrame: View {
    let time: Double
    let size: Double

    var body: some View {
        VStack(spacing: 8) {
            ForEach(0..<4) { row in
                HStack(spacing: 8) {
                    ForEach(0..<6) { column in
                        let index = row * 6 + column
                        BotAvatarStill(
                            seed: "benchmark-\(index)", size: size,
                            state: [BotState.idle, .working, .sleeping][index % 3], time: time)
                    }
                }
            }
        }
        .padding(16)
    }
}
