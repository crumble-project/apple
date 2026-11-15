import Foundation
import Observation

/// The list's two views.
public enum AutomationsView: Hashable, Sendable {
  case automations, runs
}

/// The account's automations and their runs. Saving, pausing and deleting apply at once and undo on
/// failure, with a failed save giving its draft back. Starting a run depends on the server, so it only
/// shows as pending until confirmed. Results that return after the connection changed are dropped.
@MainActor @Observable
public final class AutomationBoard {
  private var loaded: [Schedule] = []
  public private(set) var isLoaded = false
  public private(set) var readError: String?
  private var order = ReadOrder()
  /// Local versions of rows the server hasn't confirmed, so a read can't undo them.
  private var pending: [String: Schedule] = [:]
  /// Hidden until the server answers, so a read can't bring them back.
  private var deleting: Set<String> = []
  /// Runs being started, which disable Run Now.
  public private(set) var starting: Set<String> = []
  /// Why an action on a row failed, by automation.
  public private(set) var errors: [String: String] = [:]

  /// The open sheet.
  public var draft: AutomationDraft?
  public private(set) var saveError = ""
  /// Failed saves waiting for the open sheet to close.
  private var returned: [(draft: AutomationDraft, error: String)] = []
  /// The server's preview of the open draft's trigger, and the draft and request it answered.
  private var preview: (draft: UUID, request: AutomationPreviewRequest, value: AutomationPreview)?

  public var view = AutomationsView.automations
  public var filter = AutomationFilter.all

  private var executions: [Execution] = []
  private var scriptRuns: [String: [ScriptRun]] = [:]
  public private(set) var runsLoaded = false
  public private(set) var runsError: String?
  private var runOrder = ReadOrder()
  private var scope = 0

  public init() {}

  public func reset() {
    scope += 1
    loaded = []
    isLoaded = false
    readError = nil
    order = ReadOrder()
    pending = [:]
    deleting = []
    starting = []
    errors = [:]
    draft = nil
    saveError = ""
    returned = []
    preview = nil
    view = .automations
    filter = .all
    executions = []
    scriptRuns = [:]
    runsLoaded = false
    runsError = nil
    runOrder = ReadOrder()
  }

  public var schedules: [Schedule] {
    let confirmed = loaded.filter { !deleting.contains($0.id) }.map { pending[$0.id] ?? $0 }
    let saved = Set(loaded.map(\.id))
    let new = pending.filter { !saved.contains($0.key) }.values.sorted { $0.name < $1.name }
    return confirmed + new
  }

  public func isPending(_ id: String) -> Bool { pending[id] != nil || deleting.contains(id) }

  /// The rows the current filter shows.
  public var shown: [Schedule] { listedAutomations(schedules).filter(filter.includes) }

  public func count(_ filter: AutomationFilter) -> Int {
    listedAutomations(schedules).filter(filter.includes).count
  }

  /// What a bot's details list shows: a finished one-time run has nothing left to pause.
  public func schedules(on agentID: String) -> [Schedule] {
    schedules.filter { $0.agentId == agentID && !$0.isFinished }
  }

  public var runs: [AutomationRun] {
    automationRuns(
      schedules: schedules, executions: executions, scriptRuns: scriptRuns.values.flatMap(\.self))
  }

  public func refresh(client: APIClient, includingRuns: Bool = false) {
    let version = scope
    let read = order.begin()
    Task {
      do {
        let items = try await client.schedules()
        if scope == version, order.accept(read) {
          loaded = items
          isLoaded = true
          readError = nil
        }
      } catch {
        if scope == version, order.accept(read) { readError = friendlyError(error) }
      }
      if includingRuns, scope == version { await loadRuns(client: client) }
    }
  }

  private func loadRuns(client: APIClient) async {
    let version = scope
    let read = runOrder.begin()
    let scripts = schedules.filter { $0.kind == .script }.map(\.id)
    do {
      let executions = try await client.executions()
      // One script's history failing shouldn't hide every other run.
      let runs = await withTaskGroup(of: (String, [ScriptRun]?).self) { group in
        for id in scripts { group.addTask { (id, try? await client.scriptRuns(id)) } }
        var results: [(String, [ScriptRun]?)] = []
        for await result in group { results.append(result) }
        return results
      }
      guard scope == version, runOrder.accept(read) else { return }
      self.executions = executions
      for (id, items) in runs { if let items { scriptRuns[id] = items } }
      runsLoaded = true
      runsError = nil
    } catch {
      guard scope == version, runOrder.accept(read) else { return }
      runsError = friendlyError(error)
    }
  }

  /// Refreshes the list while it is on screen, so the server's next-run labels stay current.
  public func follow(client: APIClient, every interval: Duration = .seconds(60)) async {
    while !Task.isCancelled {
      try? await Task.sleep(for: interval)
      guard !Task.isCancelled else { return }
      if view == .automations { refresh(client: client) }
    }
  }

  /// The preview of the open draft; nil while it loads, after it failed, or once the trigger changed.
  public var draftPreview: AutomationPreview? {
    guard let draft, let preview, preview.draft == draft.id, preview.request == draft.previewRequest else { return nil }
    return preview.value
  }

  /// Asks the server about the open draft's trigger once it has held for `delay`. Cancelling the task, as
  /// SwiftUI does when the trigger changes, drops the request; an answer for an earlier trigger, another
  /// draft, or another connection is ignored. A failed request leaves no preview and saving still works.
  public func loadPreview(client: APIClient, after delay: Duration = .milliseconds(250)) async {
    guard let form = draft, draftPreview == nil else { return }
    let (version, request) = (scope, form.previewRequest)
    try? await Task.sleep(for: delay)
    guard !Task.isCancelled, let loaded = try? await client.previewAutomation(request), !Task.isCancelled,
      scope == version, draft?.id == form.id, draft?.previewRequest == request
    else { return }
    preview = (form.id, request, loaded)
  }

  /// Never replaces an open sheet: it may hold what the owner typed, or a save that came back.
  public func openNew(agentID: String) {
    guard draft == nil else { return }
    saveError = ""
    draft = AutomationDraft(agentID: agentID)
  }

  public func edit(_ schedule: Schedule) {
    guard draft == nil else { return }
    guard let opened = AutomationDraft(schedule: schedule) else {
      errors[schedule.id] = "This automation has an invalid run time."
      return
    }
    saveError = ""
    draft = opened
  }

  public func closeDraft() {
    draft = nil
    saveError = ""
    preview = nil
    if !returned.isEmpty {
      let next = returned.removeFirst()
      draft = next.draft
      saveError = next.error
    }
  }

  /// For moving to another page. A sheet showing an error stays: it holds the only copy of what was typed.
  public func closeUnchangedDraft() {
    if saveError.isEmpty { closeDraft() }
  }

  /// `failed` runs when the server refuses the save, which gives the draft back.
  public func saveDraft(client: APIClient, failed: @escaping @MainActor () -> Void = {}) {
    guard let form = draft else { return }
    // Without a preview the server checks the trigger as it saves.
    let preview = draftPreview
    if let problem = form.problem ?? preview.flatMap({ $0.isProblem ? $0.text : nil }) {
      saveError = problem
      return
    }
    let id = form.isNew ? "pending-schedule-" + UUID().uuidString : form.scheduleID
    guard pending[id] == nil else { return }
    let version = scope
    pending[id] = form.provisional(id: id, replacing: loaded.first { $0.id == id }, preview: preview)
    closeDraft()
    errors[id] = nil
    Task {
      do {
        let saved = form.isNew
          ? try await client.createSchedule(form.payload)
          : try await client.updateSchedule(form.scheduleID, patch: form.payload)
        guard scope == version else { return }
        order.settle()
        store(saved)
      } catch {
        guard scope == version else { return }
        giveBack(form, error: friendlyError(error))
        failed()
      }
      pending[id] = nil
      refresh(client: client)
    }
  }

  private func giveBack(_ failed: AutomationDraft, error: String) {
    guard draft == nil else {
      returned.append((failed, error))
      return
    }
    draft = failed
    saveError = error
  }

  private func store(_ saved: Schedule) {
    if let index = loaded.firstIndex(where: { $0.id == saved.id }) {
      loaded[index] = saved
    } else {
      loaded.append(saved)
    }
  }

  /// Pauses or resumes at once. Only `enabled` is sent, so nothing else about the automation can change.
  public func setEnabled(_ schedule: Schedule, _ enabled: Bool, client: APIClient) {
    let id = schedule.id
    guard schedule.enabled != enabled, !isPending(id), var row = schedules.first(where: { $0.id == id }) else { return }
    row.enabled = enabled
    row.timing = enabled ? row.description : "Paused · " + row.description
    row.nextRunLabel = enabled ? "Saving…" : "—"
    pending[id] = row
    errors[id] = nil
    let version = scope
    Task {
      do {
        let saved = try await client.updateSchedule(id, patch: ["enabled": .bool(enabled)])
        guard scope == version else { return }
        order.settle()
        store(saved)
      } catch {
        guard scope == version else { return }
        errors[id] = friendlyError(error)
      }
      pending[id] = nil
      refresh(client: client)
    }
  }

  public func delete(_ schedule: Schedule, client: APIClient) {
    let id = schedule.id
    guard !isPending(id) else { return }
    deleting.insert(id)
    errors[id] = nil
    let version = scope
    Task {
      do {
        try await client.deleteSchedule(id)
        guard scope == version else { return }
        order.settle()
        loaded.removeAll { $0.id == id }
      } catch {
        guard scope == version else { return }
        errors[id] = friendlyError(error)
      }
      deleting.remove(id)
      refresh(client: client)
    }
  }

  /// Starts a run. `finished` gets the failure, or nil once the server has admitted it.
  public func run(
    _ schedule: Schedule, client: APIClient, finished: @escaping @MainActor (String?) -> Void
  ) {
    let id = schedule.id
    guard schedule.enabled, starting.insert(id).inserted else { return }
    errors[id] = nil
    let version = scope
    Task {
      do {
        _ = try await client.runSchedule(id)
        guard scope == version else { return }
        starting.remove(id)
        finished(nil)
      } catch {
        guard scope == version else { return }
        starting.remove(id)
        let message = friendlyError(error)
        errors[id] = message
        finished(message)
      }
      refresh(client: client, includingRuns: true)
    }
  }
}
