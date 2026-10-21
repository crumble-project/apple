import apfelkern
import Foundation

/// The kinds of background job a bot runs: coding jobs in its workspace, desktop jobs on its bot desktop.
enum JobKind: String, CaseIterable, Hashable, Sendable {
    case coding, desktop

    /// Lowercase, for sentences: "coding job".
    var noun: String {
        switch self {
        case .coding: "coding job"
        case .desktop: "desktop job"
        }
    }

    var icon: String {
        switch self {
        case .coding: "hammer.fill"
        case .desktop: "display"
        }
    }

    /// The message origin of the job's reports in the bot chat.
    var originKind: String {
        switch self {
        case .coding: CodingJob.originKind
        case .desktop: DesktopJob.originKind
        }
    }
}

/// A job as the chat shows it, of either kind.
struct Job: Hashable, Identifiable, Sendable {
    var kind: JobKind
    var name: String
    var status: String
    var usage: JobUsage?

    var id: String { Job.id(kind, name) }
    var isWorking: Bool { status == "working" }

    static func id(_ kind: JobKind, _ name: String) -> String { kind.rawValue + "/" + name }

    init(kind: JobKind, name: String, status: String, usage: JobUsage? = nil) {
        self.kind = kind
        self.name = name
        self.status = status
        self.usage = usage
    }

    /// The job a successful `coding` or `desktop` tool result names.
    init?(message: Message) {
        if let job = CodingJob(message: message) {
            self.init(kind: .coding, name: job.name, status: job.status)
        } else if let job = DesktopJob(message: message) {
            self.init(kind: .desktop, name: job.name, status: job.status)
        } else {
            return nil
        }
    }
}

/// A job's history as the job sheet shows it, oldest first.
struct JobHistory: Identifiable {
    let agentID: String
    let kind: JobKind
    let name: String
    var messages: [Message] = []
    var hasMore = false
    var oldestEntryID = ""
    var loaded = false
    var loadingOlder = false
    var error = ""

    var id: String { agentID + "/" + Job.id(kind, name) }
}

/// Tokens and cost of a job's own model requests, as one short line: "1,000 in · 500 out · $0.0020".
func usageLine(_ usage: JobUsage, locale: Locale = .current) -> String {
    let count = IntegerFormatStyle<Int>.number.locale(locale)
    let cost = usage.cost.formatted(.currency(code: "USD").precision(.fractionLength(4)).locale(locale))
    return "\(usage.inputTokens.formatted(count)) in · \(usage.outputTokens.formatted(count)) out · \(cost)"
}

extension AppModel {
    // MARK: Jobs

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

    /// The Bot desktop toggle appears when the server has a desktop image. A bot that already has
    /// one keeps the toggle if the server can't be asked, so the owner can still turn it off.
    func offersDesktop(for draft: AgentDraft) -> Bool {
        (capabilities?.desktop ?? false) || draft.toolsDesktop
    }

    private func jobKinds(in messages: [Message]) -> Set<JobKind> {
        Set(messages.compactMap { message in
            Job(message: message)?.kind ?? JobKind.allCases.first { $0.originKind == message.origin?.kind }
        })
    }

    private func jobActivityCount(in messages: [Message]) -> Int {
        let origins = Set(JobKind.allCases.map(\.originKind))
        return messages.filter { Job(message: $0) != nil || origins.contains($0.origin?.kind ?? "") }.count
    }

    /// A job's status changes when it starts and when its report reaches the chat, so a change in
    /// the chat's job messages is the cue to ask the server again.
    func refreshJobsIfChanged() {
        let activity = jobActivityCount(in: messages)
        guard activity != jobActivity else { return }
        jobActivity = activity
        for kind in jobKinds(in: messages) { refreshJobs(kind) }
    }

    func refreshJobs(_ kind: JobKind) {
        guard let client else { return }
        let agentID = selectedAgentID
        let version = selectionVersion
        Task {
            let listed: [Job]
            do {
                switch kind {
                case .coding:
                    listed = try await client.codingJobs(agentID).map {
                        Job(kind: .coding, name: $0.name, status: $0.status, usage: $0.usage)
                    }
                case .desktop:
                    listed = try await client.desktopJobs(agentID).map {
                        Job(kind: .desktop, name: $0.name, status: $0.status, usage: $0.usage)
                    }
                }
            } catch {
                return
            }
            guard selectionVersion == version, selectedAgentID == agentID else { return }
            let previous = jobs
            jobs = jobs.filter { $0.value.kind != kind }
            for job in listed { jobs[job.id] = job }
            if let open = jobHistory, open.agentID == agentID, open.kind == kind,
                previous[Job.id(kind, open.name)]?.status != jobs[Job.id(kind, open.name)]?.status {
                loadJobHistory()
            }
        }
    }

    /// The job as the card should show it: the server's current status wins over the status the
    /// tool result recorded when it ran.
    func job(_ recorded: Job) -> Job {
        jobs[recorded.id] ?? recorded
    }

    func openJob(_ kind: JobKind, _ name: String) {
        jobHistory = JobHistory(agentID: selectedAgentID, kind: kind, name: name)
        loadJobHistory()
    }

    func closeJob() {
        jobHistory = nil
    }

    private func history(of open: JobHistory, before: String, client: APIClient) async throws
        -> ChatHistoryResponse {
        switch open.kind {
        case .coding:
            try await client.codingJobHistory(open.agentID, name: open.name, before: before, limit: 100)
        case .desktop:
            try await client.desktopJobHistory(open.agentID, name: open.name, before: before, limit: 100)
        }
    }

    func loadJobHistory() {
        guard let open = jobHistory, let client else { return }
        let key = open.id
        Task {
            do {
                let page = try await history(of: open, before: "", client: client)
                // Changed as a copy: reading the observed property while writing it is an exclusivity violation.
                guard var history = jobHistory, history.id == key else { return }
                history.messages = mergeMessages(history.messages, page.messages ?? [])
                if !history.loaded {
                    history.hasMore = page.hasMore ?? false
                    history.oldestEntryID = page.oldestEntryId ?? ""
                }
                history.loaded = true
                history.error = ""
                jobHistory = history
            } catch {
                guard jobHistory?.id == key else { return }
                jobHistory?.error = friendlyError(error)
            }
        }
    }

    func loadOlderJobHistory() {
        guard let open = jobHistory, open.hasMore, !open.loadingOlder, !open.oldestEntryID.isEmpty,
            let client else { return }
        let key = open.id
        jobHistory?.loadingOlder = true
        Task {
            do {
                let page = try await history(of: open, before: open.oldestEntryID, client: client)
                guard var history = jobHistory, history.id == key else { return }
                history.messages = mergeMessages(history.messages, page.messages ?? [])
                history.hasMore = page.hasMore ?? false
                history.oldestEntryID = page.oldestEntryId ?? ""
                history.loadingOlder = false
                jobHistory = history
            } catch {
                guard jobHistory?.id == key else { return }
                jobHistory?.loadingOlder = false
                jobHistory?.error = friendlyError(error)
            }
        }
    }
}
