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
      HStack(spacing: 10) {
        Image(systemName: job.kind.icon).foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 2) {
          Text(job.name).font(.subheadline.weight(.medium)).lineLimit(1)
          HStack(spacing: 5) {
            if job.isWorking { ProgressView().controlSize(.mini) }
            Text(job.isWorking ? "Working" : "Idle").font(.caption).foregroundStyle(.secondary)
          }
        }
        Spacer(minLength: 12)
        Image(systemName: "chevron.right").font(.caption2.weight(.medium)).foregroundStyle(.tertiary)
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 10)
      .frame(maxWidth: 340, minHeight: 44, alignment: .leading)
      .background(Color.primary.opacity(0.07), in: .rect(cornerRadius: 14))
      .contentShape(.rect(cornerRadius: 14))
    }
    .buttonStyle(.plain)
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
        Image(systemName: "questionmark.bubble").foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 2) {
          Text(text).font(.subheadline.weight(.medium))
          Text(model.jobBoard.codingJobsListed ? "Answered" : "Loading…")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 10)
      .frame(maxWidth: 340, alignment: .leading)
      .background(Color.primary.opacity(0.07), in: .rect(cornerRadius: 14))
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
        Text(answer.error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
      }
    }
    .padding(12)
    .frame(maxWidth: 380, alignment: .leading)
    .background(Color.primary.opacity(0.07), in: .rect(cornerRadius: 14))
  }

  private var header: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: "questionmark.bubble").foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 2) {
        Text(question.allowsMultiple ? "\(job) asks · pick any" : "\(job) asks")
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
        Text(question.text).font(.subheadline.weight(.medium)).textSelection(.enabled)
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
          ProgressView().controlSize(.small).frame(width: 32, height: 32)
        } else {
          Image(systemName: "arrow.up.circle.fill").font(.title2).frame(width: 32, height: 32)
        }
      }
      .buttonStyle(.borderless)
      .disabled(reply.isEmpty || answer.sending)
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
      HStack(spacing: 10) {
        if !multiple && answer.sent == option {
          ProgressView().controlSize(.small).frame(width: 20)
        } else {
          Image(systemName: multiple ? (picked ? "checkmark.square.fill" : "square") : "circle")
            .foregroundStyle(picked ? .primary : .secondary)
            .frame(width: 20)
        }
        Text(option).font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(.horizontal, 8)
      .frame(minHeight: 44)
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
  @State private var desktop: BotDesktopTarget?
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
    NavigationStack {
      ScrollView { entries }
        .defaultScrollAnchor(.bottom)
        .overlay { placeholder }
        .safeAreaInset(edge: .top, spacing: 0) { questionBox }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .fileExporter(
          isPresented: exporting, item: job.transcript, contentTypes: [JobTranscript.contentType],
          defaultFilename: job.transcript?.filename
        ) { _ in }
        .fullScreenCover(item: $desktop) { BotDesktopView(agentID: $0.id) }
    }
  }

  @ToolbarContentBuilder private var toolbar: some ToolbarContent {
    ToolbarItem(placement: .cancellationAction) {
      Button(role: .close) { model.closeJob() }
    }
    ToolbarItem(placement: .principal) {
      VStack(spacing: 2) {
        Text(job.name).font(.headline).lineLimit(1)
        if let summary = current?.summary().nilIfEmpty {
          Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.75)
        }
      }
    }
    ToolbarItemGroup(placement: .primaryAction) {
      if job.kind == .desktop {
        Button("Bot Desktop", systemImage: JobKind.desktop.icon) {
          desktop = BotDesktopTarget(id: job.agentID)
        }
      }
      Button("Download Transcript", systemImage: "square.and.arrow.down") {
        model.downloadJobTranscript()
      }
      .disabled(job.downloading)
    }
  }

  @ViewBuilder private var questionBox: some View {
    if let question = current?.question {
      JobQuestionAnswerView(job: job.name, question: question)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }
  }

  private var entries: some View {
    LazyVStack(alignment: .leading, spacing: 12) {
      if job.hasMore {
        if job.loadingOlder {
          ProgressView().controlSize(.small).frame(maxWidth: .infinity)
        } else {
          Button("Load Earlier Activity") { model.loadOlderJobHistory() }
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 44)
        }
      }
      ForEach(notices, id: \.self) { notice in
        Label(notice, systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
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
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var notices: [String] {
    [items.isEmpty ? "" : job.error, job.transcriptError].filter { !$0.isEmpty }
  }

  @ViewBuilder private var placeholder: some View {
    if !job.error.isEmpty && items.isEmpty {
      VStack(spacing: 8) {
        Text("Couldn’t load this \(job.kind.noun)").font(.subheadline.weight(.medium))
        Text(job.error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
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
        Text("Task").font(.caption).foregroundStyle(.secondary)
        Text(text)
          .textSelection(.enabled)
          .padding(.horizontal, 14)
          .padding(.vertical, 10)
          .background(Color.accentColor.opacity(0.12), in: .rect(cornerRadius: 14))
      }
      .accessibilityElement(children: .combine)
    case .reply(_, let text):
      MarkdownText(text: text)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    case .tool(let tool):
      CodingToolStep(tool: tool)
    }
  }
}

/// One tool call: what ran (a command or a file). Tap it to see the whole output, which a phone
/// has no room to show for every step.
private struct CodingToolStep: View {
  let tool: CodingJobItem.Tool
  @State private var open = false

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

  private var summary: some View {
    Button {
      open.toggle()
    } label: {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Image(systemName: tool.isError ? "exclamationmark.triangle.fill" : icon)
          .foregroundStyle(tool.isError ? .red : .secondary)
          .frame(width: 18)
        Text(verb).foregroundStyle(.secondary)
        Text(tool.subject).font(.caption.monospaced()).lineLimit(open ? nil : 2)
        if !tool.finished { ProgressView().controlSize(.mini) }
        Spacer(minLength: 0)
      }
      .font(.callout)
      .frame(minHeight: 32)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(!tool.finished)
    .accessibilityLabel("\(verb) \(tool.subject)\(tool.isError ? ", failed" : "")")
    .accessibilityValue(open ? "Expanded" : "Collapsed")
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      summary
      if open {
        Text(tool.shownOutput)
          .font(.caption.monospaced())
          .foregroundStyle(tool.isError ? Color.red : Color.primary)
          .textSelection(.enabled)
          .padding(10)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 10))
      }
    }
  }
}
