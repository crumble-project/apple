import apfelkern
import Foundation

extension AppModel {
  // MARK: Jobs

  var jobs: [String: Job] { jobBoard.jobs }

  var jobHistory: JobHistory? {
    get { jobBoard.history }
    set { jobBoard.history = newValue }
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
