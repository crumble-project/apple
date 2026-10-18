import Foundation

extension AppModel {
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
        if let message = validateTask(name: name, prompt: prompt, cron: cron, runAt: runAt, timezone: timezone) {
            errorText = message
            return
        }
        let payload: [String: JSONValue] = [
            "agentId": .string(form.agentID), "name": .string(name), "prompt": .string(prompt),
            "timezone": .string(timezone), "enabled": .bool(form.enabled)
        ]
        let isNew = form.scheduleID.isEmpty
        let provisionalID = isNew ? "pending-schedule-" + newRequestID() : form.scheduleID
        let provisional = Schedule(
            id: provisionalID, agentId: form.agentID, name: name, cron: form.repeats ? cron : nil,
            prompt: prompt, timezone: timezone, runAt: form.repeats ? nil : runAt, enabled: form.enabled,
            createdByAgentId: nil)
        persistTask(form, provisional: provisional, payload: payload)
    }

    private func persistTask(_ form: TaskDraft, provisional: Schedule, payload: [String: JSONValue]) {
        let isNew = form.scheduleID.isEmpty
        let provisionalID = provisional.id
        var payload = payload
        let old = schedules.first { $0.id == form.scheduleID }
        taskDraft = nil
        optimisticMutation(
            key: "schedule:\(provisionalID)",
            update: { [self] in
                if let index = schedules.firstIndex(where: { $0.id == provisionalID || $0.id == form.scheduleID }) {
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
                let saved: Schedule
                if isNew {
                    if form.repeats {
                        payload["cron"] = .string(provisional.cron ?? "")
                    } else {
                        payload["runAt"] = .string(provisional.runAt ?? "")
                    }
                    saved = try await client.createSchedule(payload)
                } else {
                    payload["cron"] = (provisional.cron ?? "").isEmpty ? .null : .string(provisional.cron ?? "")
                    payload["runAt"] = form.repeats ? .null : .string(provisional.runAt ?? "")
                    saved = try await client.updateSchedule(form.scheduleID, patch: payload)
                }
                return { [self] in
                    if let index = schedules.firstIndex(where: { $0.id == provisionalID }) { schedules[index] = saved }
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
                        let agent = execution.agentId, !agent.isEmpty {
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
            key: "schedule:\(id)",
            update: { [self] in
                schedules.removeAll { $0.id == id }
            },
            rollback: { [self] in
                schedules.insert(old, at: min(index, schedules.count))
            },
            work: { client in
                try await client.deleteSchedule(id)
                return nil
            })
    }
}
