import apfelkern

/// The call open beside the chat and what its transcript showed last.
struct OpenCall: Equatable {
    var request: CallRequest
    /// Tells this opening from an earlier one of the same call.
    var opening: Int
    var lines: [CallTranscriptLine] = []
    var loaded = false
    var failed = false
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

    /// Selecting the open call's card again closes it.
    func openCall(_ request: CallRequest) {
        if openCall?.request.id == request.id { return closeCall() }
        callOpenings += 1
        jobBoard.close()
        openCall = OpenCall(request: request, opening: callOpenings)
    }

    func closeCall() { openCall = nil }

    /// Loads the open call's transcript, then again every two seconds while it is going on, and once
    /// more after it ends. Runs until cancelled.
    func watchCallTranscript() async {
        guard let opening = openCall?.opening else { return }
        while !Task.isCancelled {
            guard let open = openCall, open.opening == opening else { return }
            let calling = callRequestBoard.current(open.request).status == .calling
            await loadCallTranscript(opening: opening)
            guard calling else { return }
            try? await Task.sleep(for: callPollInterval)
        }
    }

    private func loadCallTranscript(opening: Int) async {
        guard let client, let open = openCall, open.opening == opening else { return }
        do {
            let page = try await client.callRequestTranscript(
                open.request.agentID, id: open.request.id, before: "", limit: 200)
            guard openCall?.opening == opening else { return }
            openCall?.lines = callTranscriptLines(page.messages ?? [])
            openCall?.loaded = true
            openCall?.failed = false
        } catch {
            guard openCall?.opening == opening else { return }
            openCall?.failed = true
        }
    }
}
