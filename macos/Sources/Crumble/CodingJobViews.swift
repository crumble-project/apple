import apfelkern
import SwiftUI

/// A coding job a bot started, in the chat: its name and whether it is still working.
struct CodingJobCard: View {
    @Environment(AppModel.self) private var model
    let job: CodingJob

    var body: some View {
        Button {
            model.openCodingJob(job.name)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "hammer.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.name).font(.system(size: 14, weight: .medium)).lineLimit(1)
                    HStack(spacing: 5) {
                        if job.isWorking { ProgressView().controlSize(.mini) }
                        Text(job.isWorking ? "Working" : "Idle").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 16)
                Image(systemName: "chevron.right").font(.caption2.weight(.medium)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: 340, alignment: .leading)
            .background(Palette.bubble, in: .rect(cornerRadius: 14))
            .contentShape(.rect(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .help("Open coding job")
        .accessibilityLabel("Coding job \(job.name), \(job.isWorking ? "working" : "idle")")
        .accessibilityHint("Opens the job")
    }
}

/// A read-only view of one coding job: its task, what the bot said, and the work it did.
struct CodingJobSheet: View {
    @Environment(AppModel.self) private var model
    let job: CodingJobHistory

    private var items: [CodingJobItem] { CodingJobItem.items(from: job.messages) }
    private var working: Bool { model.codingJobs[job.name]?.isWorking ?? false }

    var body: some View {
        ScrollView { entries }
        .defaultScrollAnchor(.bottom)
        .overlay { placeholder }
        .frame(width: 600, height: 560)
        .navigationTitle(job.name)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { model.closeCodingJob() }.keyboardShortcut(.cancelAction)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.loadCodingJobHistory()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Refresh")
            }
        }
    }

    private var entries: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            if job.hasMore {
                if job.loadingOlder {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                } else {
                    Button("Load Earlier Activity") { model.loadOlderCodingJobHistory() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            if !job.error.isEmpty && !items.isEmpty {
                Label(job.error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            ForEach(items) { item in
                CodingJobItemView(item: item)
            }
            if working && job.loaded {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Working…").foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var placeholder: some View {
        if !job.error.isEmpty && items.isEmpty {
            VStack(spacing: 8) {
                Text("Couldn’t load this coding job").font(.system(size: 14, weight: .medium))
                Text(job.error).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
                Button("Try Again") { model.loadCodingJobHistory() }
            }
            .padding(24)
        } else if !job.loaded {
            ProgressView()
        } else if items.isEmpty {
            Text("Nothing here yet").foregroundStyle(.secondary)
        }
    }
}

private struct CodingJobItemView: View {
    let item: CodingJobItem

    var body: some View {
        switch item {
        case .task(_, let text):
            VStack(alignment: .leading, spacing: 4) {
                Text("Task").font(.system(size: 12)).foregroundStyle(.secondary)
                Text(text)
                    .font(Palette.messageFont)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.accentColor.opacity(0.12), in: .rect(cornerRadius: 14))
            }
            .accessibilityElement(children: .combine)
        case .reply(_, let text):
            MarkdownText(text: text)
                .font(Palette.messageFont)
                .lineSpacing(Palette.messageLineSpacing)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .tool(let tool):
            CodingToolStep(tool: tool)
        }
    }
}

/// One tool call: what ran (a command or a file), and its output when that helps.
private struct CodingToolStep: View {
    static let outputLines = 12
    let tool: CodingJobItem.Tool

    private var icon: String {
        switch tool.name {
        case "bash": "terminal"
        case "read": "doc.text"
        case "write": "square.and.pencil"
        case "edit": "pencil"
        default: "wrench.and.screwdriver"
        }
    }

    private var verb: String {
        switch tool.name {
        case "bash": "Ran"
        case "read": "Read"
        case "write": "Wrote"
        case "edit": "Edited"
        default: tool.name.capitalized
        }
    }

    private var shownOutput: (text: String, omitted: Int)? {
        guard tool.name == "bash" || tool.isError else { return nil }
        let tail = tailLines(tool.output, maxLines: Self.outputLines)
        return tail.text.isEmpty ? nil : tail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: tool.isError ? "exclamationmark.triangle.fill" : icon)
                    .foregroundStyle(tool.isError ? .red : .secondary)
                    .frame(width: 16)
                Text(verb).foregroundStyle(.secondary)
                Text(tool.subject)
                    .font(.system(size: 12.5, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(4)
                if !tool.finished { ProgressView().controlSize(.mini) }
            }
            .font(.system(size: 12.5))
            if let output = shownOutput {
                VStack(alignment: .leading, spacing: 2) {
                    if output.omitted > 0 {
                        Text("\(output.omitted) earlier lines not shown").font(.caption).foregroundStyle(.tertiary)
                    }
                    Text(output.text)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(tool.isError ? Color.red : Color.primary)
                        .textSelection(.enabled)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 10))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(verb) \(tool.subject)\(tool.isError ? ", failed" : "")")
    }
}
