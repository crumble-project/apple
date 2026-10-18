import Foundation

extension AppModel {
  // MARK: Workspace panels

  func openPanel(_ panel: Route) {
    route = panel
    memoryDraft = nil
    taskDraft = nil
    mcpDraft = nil
    skillDraft = nil
    switch panel {
    case .memory:
      memoryLoadVersion += 1
      let version = memoryLoadVersion
      let mutationVersion = mutationRevision
      request { client in
        let bots = try await client.agents()
        async let shared = client.memories(nil)
        let personal = try await withThrowingTaskGroup(of: (String, [Memory]).self) { group in
          for bot in bots {
            group.addTask { (bot.id, try await client.memories(bot.id)) }
          }
          var result: [String: [Memory]] = [:]
          for try await (id, memories) in group { result[id] = memories }
          return result
        }
        let sharedItems = try await shared
        return { [self] in
          guard memoryLoadVersion == version, mutationRevision == mutationVersion,
            pendingMutations.isEmpty
          else { return }
          agents = bots
          sharedMemories = sharedItems
          agentMemories = personal
        }
      }
    case .skills:
      let mutationVersion = mutationRevision
      request { client in
        async let bots = client.agents()
        async let skills = client.sharedSkills()
        let (loadedBots, loadedSkills) = try await (bots, skills)
        return { [self] in
          guard mutationRevision == mutationVersion, pendingMutations.isEmpty else { return }
          agents = loadedBots
          sharedSkills = loadedSkills
        }
      }
    case .tasks:
      let mutationVersion = mutationRevision
      request { client in
        let items = try await client.schedules()
        return { [self] in
          guard mutationRevision == mutationVersion, pendingMutations.isEmpty else { return }
          schedules = items
        }
      }
    case .activity:
      request { client in
        let feed = try await client.activityFeed()
        return { [self] in activities = feed.activities }
      }
    case .integrations:
      let mutationVersion = mutationRevision
      request { client in
        async let bots = client.agents()
        async let servers = client.mcpServers()
        let (loadedBots, loadedServers) = try await (bots, servers)
        return { [self] in
          guard mutationRevision == mutationVersion, pendingMutations.isEmpty else { return }
          agents = loadedBots
          mcpServers = loadedServers
        }
      }
    case .agent:
      break
    }
  }

  /// Carries the entry's owner into the form so edits never depend on the active chat.
  func openMemoryForm(_ id: String, agentID: String? = nil) {
    let items = agentID.map { agentMemories[$0] ?? [] } ?? sharedMemories
    let existing = items.first { $0.id == id }
    memoryDraft = MemoryDraft(memoryID: id, content: existing?.content ?? "", agentID: agentID)
  }

  func saveMemory() {
    guard let form = memoryDraft else { return }
    let agent = form.agentID
    let content = form.content.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !content.isEmpty else {
      errorText = "Memory content is required."
      return
    }
    let isNew = form.memoryID.isEmpty
    let provisionalID = isNew ? "pending-memory-" + newRequestID() : form.memoryID
    let provisional = Memory(id: provisionalID, content: content, createdAt: nil)
    let old = (agent == nil ? sharedMemories : agentMemories[agent!] ?? []).first {
      $0.id == form.memoryID
    }
    memoryDraft = nil
    optimisticMutation(
      key: "memory:\(provisionalID)",
      update: { [self] in
        if agent == nil {
          if let index = sharedMemories.firstIndex(where: {
            $0.id == provisionalID || $0.id == form.memoryID
          }) {
            sharedMemories[index] = provisional
          } else {
            sharedMemories.append(provisional)
          }
        } else {
          var items = agentMemories[agent!] ?? []
          if let index = items.firstIndex(where: {
            $0.id == provisionalID || $0.id == form.memoryID
          }) {
            items[index] = provisional
          } else {
            items.append(provisional)
          }
          agentMemories[agent!] = items
        }
      },
      rollback: { [self] in
        if agent == nil {
          sharedMemories.removeAll { $0.id == provisionalID }
          if let old { sharedMemories.append(old) }
        } else {
          var items = agentMemories[agent!] ?? []
          items.removeAll { $0.id == provisionalID }
          if let old { items.append(old) }
          agentMemories[agent!] = items
        }
        if route == .memory, memoryDraft == nil { memoryDraft = form }
      },
      work: { client in
        let saved =
          isNew
          ? try await client.addMemory(agent, content: content)
          : try await client.updateMemory(agent, memoryID: form.memoryID, content: content)
        return { [self] in
          if agent == nil {
            if let index = sharedMemories.firstIndex(where: { $0.id == provisionalID }) {
              sharedMemories[index] = saved
            }
          } else if var items = agentMemories[agent!],
            let index = items.firstIndex(where: { $0.id == provisionalID })
          {
            items[index] = saved
            agentMemories[agent!] = items
          }
        }
      })
  }

  func deleteMemory(_ id: String, agentID: String? = nil) {
    let agent = agentID
    let old = (agent == nil ? sharedMemories : agentMemories[agent!] ?? []).first { $0.id == id }
    let oldIndex = (agent == nil ? sharedMemories : agentMemories[agent!] ?? []).firstIndex {
      $0.id == id
    }
    optimisticMutation(
      key: "memory:\(id)",
      update: { [self] in
        if agent == nil {
          sharedMemories.removeAll { $0.id == id }
        } else {
          agentMemories[agent!]?.removeAll { $0.id == id }
        }
      },
      rollback: { [self] in
        guard let old else { return }
        if agent == nil {
          sharedMemories.insert(
            old, at: min(oldIndex ?? sharedMemories.count, sharedMemories.count))
        } else {
          var items = agentMemories[agent!] ?? []
          items.insert(old, at: min(oldIndex ?? items.count, items.count))
          agentMemories[agent!] = items
        }
      },
      work: { client in
        try await client.deleteMemory(agent, memoryID: id)
        return nil
      })
  }

  func openTaskForm(_ id: String, agentID: String? = nil) {
    guard !agents.isEmpty else {
      errorText = "Create an agent before adding a task."
      return
    }
    let fallback = agents.contains { $0.id == selectedAgentID } ? selectedAgentID : agents[0].id
    var form = TaskDraft(scheduleID: id, agentID: agentID ?? fallback)
    if let schedule = schedules.first(where: { $0.id == id }) {
      form.agentID = schedule.agentId
      form.name = schedule.name
      form.prompt = schedule.prompt
      form.repeats = !(schedule.cron ?? "").isEmpty
      if let cron = schedule.cron, !cron.isEmpty { form.cron = cron }
      if let runAt = schedule.runAt {
        guard let date = taskRunDate(runAt) else {
          errorText = "This task has an invalid run time."
          return
        }
        form.runDate = date
      }
      form.timezone = schedule.timezone ?? TimeZone.current.identifier
      form.enabled = schedule.enabled
    }
    taskDraft = form
  }

  func saveTask() {
    guard let form = taskDraft else { return }
    let trim = { (value: String) in value.trimmingCharacters(in: .whitespacesAndNewlines) }
    let name = trim(form.name)
    let prompt = trim(form.prompt)
    let timezone = trim(form.timezone)
    let cron = form.repeats ? trim(form.cron) : ""
    let runAt = form.repeats ? "" : form.runDate.ISO8601Format()
    guard !form.agentID.isEmpty else {
      errorText = "Choose which bot runs this task."
      return
    }
    if let message = validateTask(
      name: name, prompt: prompt, cron: cron, runAt: runAt, timezone: timezone)
    {
      errorText = message
      return
    }
    var payload: [String: JSONValue] = [
      "agentId": .string(form.agentID), "name": .string(name), "prompt": .string(prompt),
      "timezone": .string(timezone), "enabled": .bool(form.enabled),
    ]
    let isNew = form.scheduleID.isEmpty
    let provisionalID = isNew ? "pending-schedule-" + newRequestID() : form.scheduleID
    let provisional = Schedule(
      id: provisionalID, agentId: form.agentID, name: name, cron: form.repeats ? cron : nil,
      prompt: prompt, timezone: timezone, runAt: form.repeats ? nil : runAt, enabled: form.enabled,
      createdByAgentId: nil)
    let old = schedules.first { $0.id == form.scheduleID }
    taskDraft = nil
    optimisticMutation(
      key: "schedule:\(provisionalID)",
      update: { [self] in
        if let index = schedules.firstIndex(where: {
          $0.id == provisionalID || $0.id == form.scheduleID
        }) {
          schedules[index] = provisional
        } else {
          schedules.append(provisional)
        }
      },
      rollback: { [self] in
        schedules.removeAll { $0.id == provisionalID }
        if let old { schedules.append(old) }
        if route == .tasks, taskDraft == nil { taskDraft = form }
      },
      work: { client in
        if isNew {
          if form.repeats {
            payload["cron"] = .string(cron)
          } else {
            payload["runAt"] = .string(runAt)
          }
          let saved = try await client.createSchedule(payload)
          return { [self] in
            if let index = schedules.firstIndex(where: { $0.id == provisionalID }) {
              schedules[index] = saved
            }
          }
        } else {
          payload["cron"] = cron.isEmpty ? .null : .string(cron)
          payload["runAt"] = form.repeats ? .null : .string(runAt)
          let saved = try await client.updateSchedule(form.scheduleID, patch: payload)
          return { [self] in
            if let index = schedules.firstIndex(where: { $0.id == provisionalID }) {
              schedules[index] = saved
            }
          }
        }
      })
  }

  func runSchedule(_ id: String) {
    let routeAtStart = route
    showNotice("Starting task…")
    optimisticMutation(
      key: "schedule-run:\(id)", update: {},
      rollback: { [self] in
        showNotice("Task could not be started")
      },
      work: { client in
        let execution = try await client.runSchedule(id)
        return { [self] in
          showNotice("Task started")
          if route == routeAtStart, routeAtStart == .tasks,
            let agent = execution.agentId, !agent.isEmpty
          {
            selectAgent(agent)
          }
        }
      })
  }

  func deleteSchedule(_ id: String) {
    guard let old = schedules.first(where: { $0.id == id }),
      let index = schedules.firstIndex(where: { $0.id == id })
    else { return }
    optimisticMutation(
      key: "schedule:\(id)", update: { [self] in schedules.removeAll { $0.id == id } },
      rollback: { [self] in schedules.insert(old, at: min(index, schedules.count)) },
      work: { client in
        try await client.deleteSchedule(id)
        return nil
      })
  }
}
