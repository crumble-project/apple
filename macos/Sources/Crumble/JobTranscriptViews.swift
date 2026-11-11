import apfelkern
import BotAvatar
import SwiftUI

/// A job's history as the panel lays it out: each task and reply on its own, and each run of steps
/// gathered into one card, the way a list of tool calls reads as one piece of work.
enum JobBlock: Identifiable {
    case item(CodingJobItem)
    case steps([CodingJobStep])

    var id: String {
        switch self {
        case .item(let item): item.id
        case .steps(let steps): "steps:" + (steps.first?.id ?? "")
        }
    }

    static func blocks(_ items: [CodingJobItem]) -> [JobBlock] {
        var blocks: [JobBlock] = []
        for item in items {
            guard case .step(let step) = item else {
                blocks.append(.item(item))
                continue
            }
            if case .steps(let run)? = blocks.last {
                blocks[blocks.count - 1] = .steps(run + [step])
            } else {
                blocks.append(.steps([step]))
            }
        }
        return blocks
    }
}

struct JobBlockView: View {
    let block: JobBlock

    var body: some View {
        switch block {
        case .item(.task(let task)):
            VStack(alignment: .trailing, spacing: 3) {
                Text("Task").font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 6)
                Text(task.text)
                    .font(Palette.messageFont)
                    .lineSpacing(Palette.messageLineSpacing)
                    .textSelection(.enabled)
                    .bubble(owner: true)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, 40)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .accessibilityElement(children: .combine)
        case .item(.reply(let reply)):
            MarkdownText(text: reply.text)
                .font(Palette.messageFont)
                .lineSpacing(Palette.messageLineSpacing)
                .textSelection(.enabled)
                .bubble(owner: false)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.trailing, 40)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .item(.step(let step)):
            JobStepRow(step: step).card()
        case .steps(let steps):
            VStack(spacing: 0) {
                ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                    if index > 0 { Divider().padding(.leading, 40) }
                    JobStepRow(step: step)
                }
            }
            .card()
        }
    }
}

/// One tool call: what ran, a command or a file. A finished one opens to show its whole output.
struct JobStepRow: View {
    let step: CodingJobStep
    @State private var open = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var icon: String {
        switch step.icon {
        case .terminal: "terminal"
        case .file: "doc.text"
        case .pencil: "pencil"
        case .pointer: JobKind.desktop.icon
        case .tool: "wrench.and.screwdriver"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            summary
            if open {
                Text(step.shownOutput)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(step.isError ? Color.red : Color.primary)
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.bubble, in: .rect(cornerRadius: 8))
                    .padding(.leading, 28)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var summary: some View {
        Button {
            // A running step has no output yet; it stays at full strength so its spinner reads.
            guard step.finished else { return }
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) { open.toggle() }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: step.isError ? "exclamationmark.triangle.fill" : icon)
                    .font(.system(size: 12))
                    .foregroundStyle(step.isError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .frame(width: 20)
                Text(step.label).font(.system(size: 12.5)).foregroundStyle(.secondary).layoutPriority(1)
                Text(step.subject ?? "")
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(open ? nil : 1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if step.finished {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(open ? 90 : 0))
                } else {
                    ProgressView().controlSize(.mini)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(step.label) \(step.subject ?? "")\(step.isError ? ", failed" : "")")
        .accessibilityValue(open ? "Expanded" : "Collapsed")
    }
}
