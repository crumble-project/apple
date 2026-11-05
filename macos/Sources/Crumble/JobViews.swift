import apfelkern
import SwiftUI

/// A job a bot started, in the chat: its kind, name, and whether it is still working.
struct JobCard: View {
    @Environment(AppModel.self) private var model
    let job: Job

    var body: some View {
        Button {
            model.openJob(job.kind, job.name)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: job.kind.icon)
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
        .help("Open \(job.kind.noun)")
        .accessibilityLabel(
            "\(job.kind.noun.capitalized(with: nil)) \(job.name), \(job.isWorking ? "working" : "idle")")
        .accessibilityHint("Opens the job")
    }
}

/// A coding job's question in the chat: an answer box while the job waits on it, then a settled card.
struct JobQuestionCard: View {
    @Environment(AppModel.self) private var model
    let question: JobQuestionEvent
    let text: String

    var body: some View {
        if let waiting = model.jobBoard.waitingQuestion(question.id) {
            JobQuestionAnswerView(job: question.job, question: waiting)
        } else {
            HStack(spacing: 10) {
                Image(systemName: "questionmark.bubble")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(text).font(.system(size: 14, weight: .medium))
                    Text(model.jobBoard.codingJobsListed ? "Answered" : "Loading…")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: 340, alignment: .leading)
            .background(Palette.bubble, in: .rect(cornerRadius: 14))
            .accessibilityElement(children: .combine)
        }
    }
}

/// The owner's answer box for a job's open question; the answer resumes the job.
struct JobQuestionAnswerView: View {
    @Environment(AppModel.self) private var model
    let job: String
    let question: JobQuestion

    private var answer: JobAnswer { model.jobBoard.answers[question.id] ?? JobAnswer() }
    private var reply: String { answer.reply(to: question) }
    private var text: Binding<String> {
        Binding(
            get: { answer.text },
            set: { model.jobBoard.answers[question.id, default: JobAnswer()].text = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            ForEach(question.options ?? [], id: \.self) { option in
                optionRow(option)
            }
            composer
            if !answer.error.isEmpty {
                Text(answer.error).font(.system(size: 12)).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .padding(12)
        .frame(maxWidth: 380, alignment: .leading)
        .background(Palette.bubble, in: .rect(cornerRadius: 14))
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "questionmark.bubble")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(question.allowsMultiple ? "\(job) asks · pick any" : "\(job) asks")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(question.text).font(.system(size: 14, weight: .medium)).textSelection(.enabled)
            }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(
                "Answer", text: text,
                prompt: Text(question.options == nil ? "Your answer…" : "Something else…"), axis: .vertical
            )
            .textFieldStyle(.roundedBorder)
            .lineLimit(1...6)
            .disabled(answer.sending)
            Button {
                submit(reply)
            } label: {
                if answer.sending, question.allowsMultiple || question.options == nil {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.up")
                }
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(reply.isEmpty || answer.sending)
            .help("Answer (⌘↩)")
            .accessibilityLabel("Answer")
        }
    }

    private func submit(_ reply: String) {
        model.answerJobQuestion(question, job: job, reply: reply)
    }

    private func optionRow(_ option: String) -> some View {
        let multiple = question.allowsMultiple
        let picked = answer.picked.contains(option) || (!multiple && answer.sent == option)
        return Button {
            if multiple {
                model.jobBoard.toggle(option, for: question.id)
            } else {
                submit(option)
            }
        } label: {
            HStack(spacing: 8) {
                if !multiple && answer.sent == option {
                    ProgressView().controlSize(.mini).frame(width: 16)
                } else {
                    Image(systemName: multiple ? (picked ? "checkmark.square.fill" : "square") : "circle")
                        .foregroundStyle(picked ? .primary : .secondary)
                        .frame(width: 16)
                }
                Text(option).font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .background(picked ? Color.primary.opacity(0.07) : .clear, in: .rect(cornerRadius: 8))
            .contentShape(.rect(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(answer.sending)
        .accessibilityAddTraits(picked ? .isSelected : [])
    }
}

/// One job: its open question, task, what the bot said, the work it did, and what it spent.
struct JobSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let job: JobHistory

    private var items: [CodingJobItem] { CodingJobItem.items(from: job.messages) }
    private var current: Job? { model.jobs[Job.id(job.kind, job.name)] }
    private var working: Bool { current?.isWorking ?? false }
    private var exporting: Binding<Bool> {
        Binding(
            get: { job.transcript != nil },
            set: { if !$0 { model.jobHistory?.transcript = nil } })
    }

    var body: some View {
        ScrollView { entries }
        .defaultScrollAnchor(.bottom)
        .overlay { placeholder }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let question = current?.question {
                JobQuestionAnswerView(job: job.name, question: question)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.bar)
            }
        }
        .frame(width: 600, height: 560)
        .navigationTitle(job.name)
        .navigationSubtitle(current?.summary() ?? "")
        .fileExporter(
            isPresented: exporting, item: job.transcript, contentTypes: [JobTranscript.contentType],
            defaultFilename: job.transcript?.filename
        ) { _ in }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { model.closeJob() }.keyboardShortcut(.cancelAction)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.loadJobHistory()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Refresh")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.downloadJobTranscript()
                } label: {
                    Label("Download Transcript", systemImage: "arrow.down.circle")
                }
                .disabled(job.downloading)
                .help(job.transcriptError.isEmpty ? "Download Transcript" : job.transcriptError)
            }
            if job.kind == .desktop {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        openWindow(id: BotDesktopView.windowID, value: job.agentID)
                    } label: {
                        Label("Open Bot Desktop", systemImage: JobKind.desktop.icon)
                    }
                    .help("Open Bot Desktop")
                }
            }
        }
    }

    private var entries: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            if job.hasMore {
                if job.loadingOlder {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                } else {
                    Button("Load Earlier Activity") { model.loadOlderJobHistory() }
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
                Text("Couldn’t load this \(job.kind.noun)").font(.system(size: 14, weight: .medium))
                Text(job.error).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
                Button("Try Again") { model.loadJobHistory() }
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
        case "computer_use": JobKind.desktop.icon
        default: "wrench.and.screwdriver"
        }
    }

    private var verb: String {
        switch tool.name {
        case "bash": "Ran"
        case "read": "Read"
        case "write": "Wrote"
        case "edit": "Edited"
        case "computer_use": "Used the bot desktop"
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
