import apfelkern
import Foundation

/// The call whose conversation the owner is reading.
struct OpenCall: Identifiable, Hashable {
  var request: CallRequest
  var lines: [CallTranscriptLine] = []
  var loaded = false
  var failed = false
  var reads = 0

  var id: String { request.id }
}

extension AppModel {
  func refreshCallRequestsIfChanged() {
    guard let client else { return }
    callRequestBoard.refreshIfChanged(messages: messages, client: client)
  }

  func watchCallRequests() async {
    guard let client, callRequestBoard.needsPolling else { return }
    await callRequestBoard.watch(client: client)
  }

  func approveCallRequest(_ request: CallRequest) {
    guard let client else { return }
    callRequestBoard.approve(request, client: client)
  }

  func declineCallRequest(_ request: CallRequest) {
    guard let client else { return }
    callRequestBoard.decline(request, client: client)
  }

  func openCall(_ request: CallRequest) {
    openedCall = OpenCall(request: callRequestBoard.current(request))
  }

  func closeCall() { openedCall = nil }

  func resetCalls() {
    callRequestBoard.reset()
    openedCall = nil
  }

  /// The open call's request as the server last reported it.
  var openCallRequest: CallRequest? {
    openedCall.map { callRequestBoard.current($0.request) }
  }

  /// Loads the open call's transcript, and again every `delay` while the call goes on, and once more after it ends.
  func watchOpenCall(every delay: Duration = .seconds(2)) async {
    guard let id = openedCall?.id else { return }
    while !Task.isCancelled, openedCall?.id == id {
      let calling = openCallRequest?.status == .calling
      await loadCallTranscript()
      guard calling else { return }
      try? await Task.sleep(for: delay)
    }
  }

  func loadCallTranscript() async {
    guard let client, let call = openedCall else { return }
    let id = call.id
    let agentID = call.request.agentID
    let connection = generation
    openedCall?.reads += 1
    let read = call.reads + 1
    let page = try? await client.callRequestTranscript(agentID, id: id)
    guard generation == connection, selectedAgentID == agentID, openedCall?.id == id,
      openedCall?.reads == read
    else { return }
    if let page {
      openedCall?.lines = callTranscriptLines(page.messages ?? [])
      openedCall?.failed = false
      openedCall?.loaded = true
    } else {
      openedCall?.failed = true
    }
  }
}
