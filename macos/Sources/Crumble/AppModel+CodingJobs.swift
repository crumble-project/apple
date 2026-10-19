import apfelkern
import Foundation

/// A coding job's history as the job view shows it, oldest first.
struct CodingJobHistory: Identifiable {
    let agentID: String
    let name: String
    var messages: [Message] = []
    var hasMore = false
    var oldestEntryID = ""
    var loaded = false
    var loadingOlder = false
    var error = ""

    var id: String { agentID + "/" + name }
}

extension AppModel {
    // MARK: Coding jobs

    /// Loaded once per connection; a failed load leaves it unknown and the next refresh tries again.
    func loadCapabilities() {
        guard capabilities == nil, let client else { return }
        let connection = generation
        Task {
            guard let loaded = try? await client.capabilities(), generation == connection else { return }
            capabilities = loaded
        }
    }

    /// The Coding toggle appears when the server can run jobs. A bot that already has coding keeps
    /// the toggle if the server can't be asked, so the owner can still turn it off.
    func offersCoding(for draft: AgentDraft) -> Bool {
        (capabilities?.coding ?? false) || draft.toolsCoding
    }

    private func isCodingActivity(_ message: Message) -> Bool {
        CodingJob(message: message) != nil || message.origin?.kind == CodingJob.originKind
    }

    /// A job's status changes when it starts and when its report reaches the chat, so a change in
    /// the chat's job messages is the cue to ask the server again.
    func refreshCodingJobsIfChanged() {
        let activity = messages.filter(isCodingActivity).count
        guard activity != codingActivity else { return }
        codingActivity = activity
        if activity > 0 { refreshCodingJobs() }
    }

    func refreshCodingJobs() {
        guard let client else { return }
        let agentID = selectedAgentID
        let version = selectionVersion
        Task {
            guard let jobs = try? await client.codingJobs(agentID),
                selectionVersion == version, selectedAgentID == agentID else { return }
            let previous = codingJobs
            codingJobs = Dictionary(jobs.map { ($0.name, $0) }, uniquingKeysWith: { $1 })
            if let open = codingJobHistory, open.agentID == agentID,
                previous[open.name]?.status != codingJobs[open.name]?.status {
                loadCodingJobHistory()
            }
        }
    }

    /// The job as the card should show it: the server's current status wins over the status the
    /// tool result recorded when it ran.
    func codingJob(_ recorded: CodingJob) -> CodingJob {
        codingJobs[recorded.name] ?? recorded
    }

    func openCodingJob(_ name: String) {
        codingJobHistory = CodingJobHistory(agentID: selectedAgentID, name: name)
        loadCodingJobHistory()
    }

    func closeCodingJob() {
        codingJobHistory = nil
    }

    func loadCodingJobHistory() {
        guard let open = codingJobHistory, let client else { return }
        let key = open.id
        Task {
            do {
                let page = try await client.codingJobHistory(open.agentID, name: open.name, before: "", limit: 100)
                // Changed as a copy: reading the observed property while writing it is an exclusivity violation.
                guard var history = codingJobHistory, history.id == key else { return }
                history.messages = mergeMessages(history.messages, page.messages ?? [])
                if !history.loaded {
                    history.hasMore = page.hasMore ?? false
                    history.oldestEntryID = page.oldestEntryId ?? ""
                }
                history.loaded = true
                history.error = ""
                codingJobHistory = history
            } catch {
                guard codingJobHistory?.id == key else { return }
                codingJobHistory?.error = friendlyError(error)
            }
        }
    }

    func loadOlderCodingJobHistory() {
        guard let open = codingJobHistory, open.hasMore, !open.loadingOlder, !open.oldestEntryID.isEmpty,
            let client else { return }
        let key = open.id
        codingJobHistory?.loadingOlder = true
        Task {
            do {
                let page = try await client.codingJobHistory(
                    open.agentID, name: open.name, before: open.oldestEntryID, limit: 100)
                guard var history = codingJobHistory, history.id == key else { return }
                history.messages = mergeMessages(history.messages, page.messages ?? [])
                history.hasMore = page.hasMore ?? false
                history.oldestEntryID = page.oldestEntryId ?? ""
                history.loadingOlder = false
                codingJobHistory = history
            } catch {
                guard codingJobHistory?.id == key else { return }
                codingJobHistory?.loadingOlder = false
                codingJobHistory?.error = friendlyError(error)
            }
        }
    }
}
