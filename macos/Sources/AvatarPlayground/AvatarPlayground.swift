import AppKit
import BotAvatar
import SwiftUI

/// A bench for bot avatars: `swift run AvatarPlayground` opens a window of faces to tune;
/// `swift run AvatarPlayground --snapshot out.png [time]` writes a still contact sheet instead.
@main
struct AvatarPlayground: App {
    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--benchmark") {
            let frames = arguments.count > index + 1 ? Int(arguments[index + 1]) ?? 300 : 300
            let size = arguments.count > index + 2 ? Double(arguments[index + 2]) ?? 44 : 44
            guard (1...10_000).contains(frames), size.isFinite, (16...200).contains(size) else { exit(1) }
            AvatarBenchmark.run(frames: frames, size: size)
            exit(0)
        }
        if let index = arguments.firstIndex(of: "--snapshot"), index + 1 < arguments.count {
            let time = arguments.count > index + 2 ? Double(arguments[index + 2]) ?? 0 : 0
            ContactSheet.write(to: URL(fileURLWithPath: arguments[index + 1]), time: time)
            exit(0)
        }
    }

    var body: some Scene {
        Window("Avatar Playground", id: "main") {
            if CommandLine.arguments.contains("--profile") {
                AvatarProfileView().frame(width: 640, height: 480)
            } else {
                PlaygroundView().frame(minWidth: 720, minHeight: 560)
            }
        }
        .defaultSize(width: 1040, height: 780)
    }
}

enum Appearance: String, CaseIterable, Identifiable {
    case system = "System", light = "Light", dark = "Dark"
    var id: Self { self }
    var scheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

struct PlaygroundView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var reactions: [String: Int] = [:]
    @State private var seeds = PlaygroundView.randomSeeds()
    @State private var selected = "crumble"
    @State private var state = BotState.idle
    @State private var live = true
    @State private var size = 96.0
    @State private var frozen = false
    @State private var time = 0.0
    @State private var appearance = Appearance.system

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                sizes
                Divider()
                LazyVGrid(columns: [GridItem(.adaptive(minimum: size + 24), spacing: 16)], spacing: 16) {
                    ForEach(seeds, id: \.self) { seed in
                        tile(seed)
                            .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    }
                }
            }
            .padding(24)
        }
        .toolbar { controls }
        .preferredColorScheme(appearance.scheme)
    }

    private var sizes: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(selected).font(.headline.monospaced())
            HStack(alignment: .bottom, spacing: 20) {
                ForEach([16.0, 24, 28, 36, 44, 64, 96, 160], id: \.self) { side in
                    VStack {
                        avatar(selected, size: side)
                        Text("\(Int(side))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func tile(_ seed: String) -> some View {
        VStack(spacing: 6) {
            avatar(seed, size: size)
            Text(seed).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(8)
        .background(
            seed == selected ? AnyShapeStyle(.tint.opacity(0.15)) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 12))
        .contentShape(.rect)
        .onTapGesture {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { selected = seed }
            reactions[seed, default: 0] += 1
        }
        .help("Click to select and greet; hover to catch their attention")
    }

    @ViewBuilder private func avatar(_ seed: String, size: Double) -> some View {
        if frozen {
            BotAvatarStill(seed: seed, size: size, state: state, time: time)
        } else {
            BotAvatarView(seed: seed, size: size, state: state, live: live, reaction: reactions[seed, default: 0])
        }
    }

    @ToolbarContentBuilder private var controls: some ToolbarContent {
        ToolbarItemGroup {
            Picker("State", selection: $state) {
                Text("Idle").tag(BotState.idle)
                Text("Working").tag(BotState.working)
                Text("Sleeping").tag(BotState.sleeping)
            }
            .pickerStyle(.segmented)
            Toggle("Live", isOn: $live).disabled(frozen)
            Toggle("Freeze", isOn: $frozen)
            Slider(value: $time, in: 0...12).frame(width: 140).disabled(!frozen).help("Moment to freeze at")
            Slider(value: $size, in: 24...200).frame(width: 120).help("Grid size")
            Picker("Appearance", selection: $appearance) {
                ForEach(Appearance.allCases) { Text($0.rawValue).tag($0) }
            }
            Button("Shuffle", systemImage: "shuffle") {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
                    seeds = Self.randomSeeds()
                    reactions = [:]
                }
            }
        }
    }

    static func randomSeeds() -> [String] {
        (0..<24).map { _ in String(UUID().uuidString.prefix(8)).lowercased() }
    }
}

/// Renders every shape and color at a few sizes and in each state into one PNG.
@MainActor
enum ContactSheet {
    static let seeds = (0..<16).map { "seed-\($0)" }

    static func write(to url: URL, time: Double) {
        let sheet = VStack(alignment: .leading, spacing: 18) {
            ForEach([BotState.idle, .working, .sleeping], id: \.self) { state in
                HStack(spacing: 10) {
                    ForEach(seeds, id: \.self) { seed in
                        BotAvatarStill(seed: seed, size: 72, state: state, time: time + Double(seed.count))
                    }
                }
            }
            HStack(spacing: 10) {
                ForEach(seeds, id: \.self) { seed in
                    BotAvatarStill(seed: seed, size: 72, state: .idle, time: time, pointer: CGPoint(x: 10, y: 10))
                }
            }
            HStack(alignment: .bottom, spacing: 14) {
                ForEach([16.0, 24, 28, 36, 44, 64, 96, 160], id: \.self) { side in
                    BotAvatarStill(seed: seeds[1], size: side, state: .idle, time: time)
                }
            }
        }
        .padding(24)
        .background(.white)
        let renderer = ImageRenderer(content: sheet)
        renderer.scale = 2
        guard let image = renderer.cgImage else { return }
        let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        try? png?.write(to: url)
    }
}
