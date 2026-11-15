import apfelkern
import BotAvatar
import SwiftUI

/// A job a bot started, in the chat: its kind, name, and whether it is still working.
struct JobCard: View {
    @Environment(AppModel.self) private var model
    let job: Job

    var body: some View {
        Button {
            model.openJob(job.kind, job.name)
        } label: {
            HStack(spacing: 12) {
                JobIcon(kind: job.kind, size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(job.name).font(.system(size: 13.5, weight: .medium)).lineLimit(1)
                    HStack(spacing: 5) {
                        if job.isWorking { ProgressView().controlSize(.mini) }
                        Text(job.isWorking ? "Working" : "Idle").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 16)
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: 340, alignment: .leading)
            .card(cornerRadius: 14)
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
            .card(cornerRadius: 14)
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
        .card(cornerRadius: 14)
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
    /// The web's 42rem; the column never takes more than half the chat.
    static let panelWidth: CGFloat = 672

    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let job: JobHistory
    var inPanel = false
    @State private var expandedSteps: Set<String> = []

    private var items: [JobHistoryItem] { job.items }
    private var current: Job? { model.jobs[Job.id(job.kind, job.name)] }
    private var working: Bool { current?.isWorking ?? false }
    private var exporting: Binding<Bool> {
        Binding(
            get: { job.transcript != nil },
            set: { if !$0 { model.jobHistory?.transcript = nil } })
    }

    @ViewBuilder var body: some View {
        if inPanel {
            log
        } else {
            log
                .frame(width: 600, height: 560)
                .navigationTitle(job.name)
                .navigationSubtitle(current?.summary() ?? "")
                .toolbar { sheetToolbar }
        }
    }

    /// The job laid out like the details panel it replaces: what it is, how it's doing, and what
    /// can be done with it, above its history. The toolbar closes it.
    private var panelHeader: some View {
        VStack(spacing: 6) {
            JobIcon(kind: job.kind, size: 56).padding(.bottom, 4)
            Text(job.name).font(.system(size: 17, weight: .semibold)).multilineTextAlignment(.center)
            HStack(spacing: 5) {
                if working { ProgressView().controlSize(.mini) }
                Text(statusLine).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            HStack(spacing: 8) {
                actionTile("Refresh", symbol: "arrow.clockwise") { model.loadJobHistory() }
                actionTile(
                    "Transcript", symbol: "arrow.down.circle",
                    help: job.transcriptError.isEmpty ? "Download Transcript" : job.transcriptError
                ) { model.downloadJobTranscript() }
                .disabled(job.downloading)
                if job.kind == .desktop {
                    actionTile("Desktop", symbol: JobKind.desktop.icon, help: "Open Bot Desktop") {
                        openWindow(id: BotDesktopView.windowID, value: job.agentID)
                    }
                }
            }
            .frame(maxWidth: 360)
            .padding(.top, 12)
        }
        .padding(.top, 8)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity)
    }

    private var statusLine: String {
        let state = working ? "Working" : job.kind.noun.prefix(1).uppercased() + job.kind.noun.dropFirst()
        return [state, current?.summary().nilIfEmpty].compactMap(\.self).joined(separator: " · ")
    }

    private func actionTile(
        _ title: String, symbol: String, help: String? = nil, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 15))
                Text(title).font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .card(cornerRadius: 10)
        .accessibilityLabel(help ?? title)
        .help(help ?? title)
    }

    private var log: some View {
        ScrollView { entries }
        .onChange(of: job.id) { expandedSteps.removeAll() }
        .defaultScrollAnchor(.bottom)
        .defaultScrollAnchor(.top, for: .alignment)
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
        .fileExporter(
            isPresented: exporting, item: job.transcript, contentTypes: [JobTranscript.contentType],
            defaultFilename: job.transcript?.filename
        ) { _ in }
    }

    @ToolbarContentBuilder private var sheetToolbar: some ToolbarContent {
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

    private var entries: some View {
        LazyVStack(alignment: .leading, spacing: 10) {
            if inPanel { panelHeader }
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
            ForEach(JobBlock.blocks(items)) { JobBlockView(block: $0, expandedSteps: $expandedSteps) }
            if working && job.loaded {
                HStack {
                    TypingDots()
                        .padding(.horizontal, 15)
                        .padding(.vertical, 14)
                        .background(Palette.bubble, in: .rect(cornerRadius: 16))
                    Spacer()
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Working")
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

/// A job's kind as a rounded tile: the card in the chat and the head of its panel.
struct JobIcon: View {
    let kind: JobKind
    let size: CGFloat

    var body: some View {
        Image(systemName: kind.icon)
            .font(.system(size: size * 0.4, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: size, height: size)
            .background(Palette.bubble, in: .rect(cornerRadius: size * 0.28))
            .accessibilityHidden(true)
    }
}
