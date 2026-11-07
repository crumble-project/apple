import apfelkern
import Foundation

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

    var jobs: [String: Job] { jobBoard.jobs }

    var jobHistory: JobHistory? {
        get { jobBoard.history }
        set { jobBoard.history = newValue }
    }

    /// A bot chat shows a job in its side column; anywhere else it opens as a sheet.
    var jobSheet: JobHistory? {
        get { if case .agent = route { nil } else { jobHistory } }
        set { jobHistory = newValue }
    }

    /// How often `watchJobs` asks the server again; nil while no open job or question needs it.
    var jobPollDelay: Duration? { jobBoard.pollDelay(messages: messages) }

    func refreshJobsIfChanged() {
        guard let client else { return }
        jobBoard.refreshIfChanged(messages: messages, agentID: selectedAgentID, client: client)
    }

    func watchJobs() async {
        guard let client, let delay = jobPollDelay else { return }
        await jobBoard.watch(every: delay, agentID: selectedAgentID, client: client)
    }

    func job(_ recorded: Job) -> Job { jobBoard.job(recorded) }

    func openJob(_ kind: JobKind, _ name: String) {
        guard let client else { return }
        jobBoard.open(kind, name, agentID: selectedAgentID, client: client)
    }

    func closeJob() { jobBoard.close() }

    func loadJobHistory() {
        guard let client else { return }
        jobBoard.loadHistory(client: client)
    }

    func loadOlderJobHistory() {
        guard let client else { return }
        jobBoard.loadOlderHistory(client: client)
    }

    func downloadJobTranscript() {
        guard let client else { return }
        jobBoard.downloadTranscript(client: client)
    }

    func answerJobQuestion(_ question: JobQuestion, job: String, reply: String) {
        guard let client else { return }
        jobBoard.answer(
            question, job: job, reply: reply, agentID: jobHistory?.agentID ?? selectedAgentID, client: client)
    }
}
