import apfelkern
import SwiftUI

/// The sections of the automation editor, inside each app's own sheet.
public struct AutomationFormSections: View {
  @Binding var draft: AutomationDraft
  let agents: [Agent]
  let capabilities: ServerCapabilities?
  let sources: [EventSource]
  /// Whether the source list has been read, so an empty one means none exist.
  let sourcesLoaded: Bool
  /// Where sources are added: the web client's Event relay settings.
  let eventRelayURL: URL?
  let client: APIClient?

  public init(
    draft: Binding<AutomationDraft>, agents: [Agent], capabilities: ServerCapabilities?, sources: [EventSource],
    sourcesLoaded: Bool, eventRelayURL: URL?, client: APIClient?
  ) {
    _draft = draft
    self.agents = agents
    self.capabilities = capabilities
    self.sources = sources
    self.sourcesLoaded = sourcesLoaded
    self.eventRelayURL = eventRelayURL
    self.client = client
  }

  private func canScript(_ agentID: String) -> Bool {
    canRunScripts(agents.first { $0.id == agentID }, capabilities: capabilities)
  }

  public var body: some View {
    Section("Automation") {
      TextField("Name", text: $draft.name, prompt: Text("Morning inbox triage"))
        .accessibilityLabel("Name")
        .onChange(of: draft.name) { _, name in
          if name.count > AutomationLimits.name { draft.name = String(name.prefix(AutomationLimits.name)) }
        }
      Picker("Runs on", selection: $draft.agentID) {
        ForEach(agents) { Text($0.name).tag($0.id) }
      }
      .onChange(of: draft.agentID) { _, agentID in
        if !canScript(agentID) { draft.kind = .prompt }
      }
      if canScript(draft.agentID) || draft.kind == .script {
        Picker("Kind", selection: $draft.kind) {
          Label("Prompt", systemImage: "text.bubble").tag(ScheduleKind.prompt)
          Label("Script", systemImage: "terminal").tag(ScheduleKind.script)
            .selectionDisabled(!canScript(draft.agentID))
        }
        .pickerStyle(.segmented)
      }
    }
    if draft.kind == .script { scriptSection } else { promptSection }
    AutomationWhenSection(
      draft: $draft, sources: sources, sourcesLoaded: sourcesLoaded, eventRelayURL: eventRelayURL, client: client)
    Section {
      Toggle("Enabled", isOn: $draft.enabled)
    }
  }

  private var promptSection: some View {
    Section("Prompt") {
      TextEditor(text: $draft.prompt)
        .frame(minHeight: 80)
        .accessibilityLabel("Prompt")
        .onChange(of: draft.prompt) { _, prompt in
          if prompt.count > AutomationLimits.prompt { draft.prompt = String(prompt.prefix(AutomationLimits.prompt)) }
        }
    }
  }

  private var scriptSection: some View {
    Section {
      TextEditor(text: $draft.command)
        .font(.body.monospaced())
        .frame(minHeight: 80)
        .autocorrectionDisabled()
        .accessibilityLabel("Command")
        .onChange(of: draft.command) { _, command in
          if command.count > AutomationLimits.command {
            draft.command = String(command.prefix(AutomationLimits.command))
          }
        }
        #if os(iOS)
          .textInputAutocapitalization(.never)
        #endif
      LabeledContent("Timeout (seconds)") {
        TextField("Timeout (seconds)", text: $draft.timeoutSeconds)
          .labelsHidden()
          .multilineTextAlignment(.trailing)
          #if os(iOS)
            .keyboardType(.numberPad)
          #endif
      }
      Toggle("Send results to the chat", isOn: $draft.notify)
    } header: {
      Text("Command")
    } footer: {
      if draft.notify {
        Text("Each finished run posts its output to the bot’s chat.").foregroundStyle(.secondary)
      }
    }
  }
}

private struct AutomationWhenSection: View {
  @Binding var draft: AutomationDraft
  let sources: [EventSource]
  let sourcesLoaded: Bool
  let eventRelayURL: URL?
  let client: APIClient?
  @State private var activeKey: PreviewKey?
  @State private var previewError = false
  @State private var retry = 0

  private var key: PreviewKey {
    PreviewKey(id: draft.id, server: client?.baseURL, token: client?.token, input: draft.previewInput, retry: retry)
  }

  var body: some View {
    Section {
      Picker("Trigger", selection: $draft.onEvent) {
        Label("Time", systemImage: "clock").tag(false)
        Label("Event", systemImage: "antenna.radiowaves.left.and.right").tag(true)
      }
      .pickerStyle(.segmented)
      if draft.onEvent { eventFields } else { timeFields }
    } header: {
      Text("When")
    } footer: {
      if let preview = draft.currentPreview(client: client) {
        Text(preview.text).foregroundStyle(preview.isProblem ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
      } else if activeKey == key, previewError {
        HStack {
          Text("Could not check the schedule.").foregroundStyle(.red)
          Button("Retry") { retry += 1 }
        }
      } else {
        ProgressView("Checking schedule…")
      }
    }
    .environment(\.timeZone, draft.zone ?? .current)
    .task(id: key) {
      let requested = key
      activeKey = requested
      previewError = false
      draft.preview = nil
      draft.previewInputUsed = nil
      draft.previewServer = nil
      draft.previewToken = nil
      guard let client else { previewError = true; return }
      do {
        try await Task.sleep(for: .milliseconds(250))
        let result = try await client.previewSchedule(requested.input)
        guard !Task.isCancelled, activeKey == requested, key == requested else { return }
        draft.preview = result
        draft.previewInputUsed = requested.input
        draft.previewServer = client.baseURL
        draft.previewToken = client.token
      } catch {
        if !Task.isCancelled, activeKey == requested, key == requested { previewError = true }
      }
    }
  }

  @ViewBuilder private var eventFields: some View {
    if sourcesLoaded, sources.isEmpty {
      let note = "Add a source in Settings › Event relay on the web first"
      if let eventRelayURL { Link(note, destination: eventRelayURL) } else { Text(note) }
    } else {
      Picker("Event source", selection: $draft.eventSourceId) {
        if draft.eventSourceId.isEmpty { Text("Choose a source").tag("") }
        // A source the list hasn't read yet keeps its value instead of a blank picker.
        if !draft.eventSourceId.isEmpty, !sources.contains(where: { $0.id == draft.eventSourceId }) {
          Text("Current source").tag(draft.eventSourceId)
        }
        ForEach(sources) { Text($0.name).tag($0.id) }
      }
    }
  }

  @ViewBuilder private var timeFields: some View {
    Picker("Repeats", selection: $draft.when) {
      ForEach(AutomationWhen.allCases) { Text($0.label).tag($0) }
    }
    switch draft.when {
    case .once:
      DatePicker("Date and time", selection: $draft.runDate)
    case .custom:
      TextField("Cron", text: $draft.cron, prompt: Text("0 9 * * 1-5"))
        .font(.body.monospaced())
        .autocorrectionDisabled()
        #if os(iOS)
          .textInputAutocapitalization(.never)
        #endif
        .onChange(of: draft.cron) { _, cron in
          if cron.count > AutomationLimits.cron { draft.cron = String(cron.prefix(AutomationLimits.cron)) }
        }
    default:
      if let recurrence = draft.recurrence { RecurrenceFields(recurrence: recurrence, draft: $draft) }
    }
    LabeledContent("Time zone") {
      TextField("Time zone", text: $draft.timezone, prompt: Text("UTC"))
        .labelsHidden()
        .multilineTextAlignment(.trailing)
        .autocorrectionDisabled()
        #if os(iOS)
          .textInputAutocapitalization(.never)
        #endif
    }
  }
}

private struct RecurrenceFields: View {
  let recurrence: Recurrence
  @Binding var draft: AutomationDraft

  private func update(_ change: (inout Recurrence) -> Void) {
    var next = recurrence
    change(&next)
    draft.recurrence = next
  }

  private var zone: TimeZone { draft.zone ?? .current }

  var body: some View {
    if recurrence.kind == .hourly {
      Picker("Minute", selection: Binding(get: { recurrence.minute }, set: { value in update { $0.minute = value } })) {
        ForEach(minutes, id: \.self) { Text(":" + String(format: "%02d", $0)).tag($0) }
      }
    } else {
      if recurrence.kind == .weekly { weekdays }
      if recurrence.kind == .monthly {
        Picker(
          "Day of the month", selection: Binding(get: { recurrence.day }, set: { value in update { $0.day = value } })
        ) {
          ForEach(1...31, id: \.self) { Text(String($0)).tag($0) }
        }
      }
      DatePicker(
        "Time",
        selection: Binding(
          get: { recurrence.time(in: zone) },
          set: { value in update { $0.setTime(value, in: zone) } }),
        displayedComponents: .hourAndMinute)
    }
  }

  /// Every five minutes, plus the current minute when a cron set another.
  private var minutes: [Int] {
    Set(stride(from: 0, to: 60, by: 5)).union([recurrence.minute]).sorted()
  }

  private var weekdays: some View {
    HStack(spacing: 4) {
      ForEach(Recurrence.week, id: \.self) { day in
        let isOn = recurrence.days.contains(day)
        // A row holds these buttons, so each needs a style or a tap on the row presses them all.
        Button { update { $0.toggle(weekday: day) } } label: {
          Text(Calendar.current.veryShortWeekdaySymbols[day])
            .fontWeight(isOn ? .bold : .regular)
            .frame(maxWidth: .infinity, minHeight: 30)
            .background(
              isOn ? AnyShapeStyle(.tint.opacity(0.25)) : AnyShapeStyle(.quaternary.opacity(0.5)), in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Calendar.current.weekdaySymbols[day])
        .accessibilityAddTraits(isOn ? .isSelected : [])
      }
    }
  }
}

private struct PreviewKey: Hashable {
  let id: UUID
  let server: String?
  let token: String?
  let input: Operations.PreviewSchedule.Input.Body.JsonPayload
  let retry: Int
}
