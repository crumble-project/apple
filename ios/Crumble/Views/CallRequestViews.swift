import apfelkern
import SwiftUI

/// A bot's proposal to phone someone other than the owner: the owner approves or declines it here.
struct CallRequestCard: View {
  @Environment(AppModel.self) private var model
  let request: CallRequest

  var body: some View {
    let live = model.callRequestBoard.current(request)
    switch live.status {
    case .pending: CallRequestPendingView(request: live)
    case .declined: CallRequestRow(request: live, detail: nil, opens: false)
    case .calling, .ended: CallRequestRow(request: live, detail: failure(live), opens: true)
    }
  }

  private func failure(_ request: CallRequest) -> String? {
    request.outcome == .failed ? request.error?.nilIfEmpty : nil
  }
}

/// A call request that is under way or over, in one line; tapping it opens the call.
struct CallRequestRow: View {
  @Environment(AppModel.self) private var model
  let request: CallRequest
  let detail: String?
  let opens: Bool

  var body: some View {
    if opens {
      Button {
        model.openCall(request)
      } label: {
        content
      }
      .buttonStyle(.plain)
      .accessibilityHint("Opens the call")
    } else {
      content
    }
  }

  private var content: some View {
    HStack(spacing: 10) {
      if request.status == .calling {
        ProgressView().controlSize(.small).frame(width: 20)
      } else {
        Image(systemName: "phone").foregroundStyle(.secondary)
      }
      VStack(alignment: .leading, spacing: 2) {
        Text(request.callee).font(.subheadline.weight(.medium)).lineLimit(1)
        if let detail {
          Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
      }
      Spacer(minLength: 12)
      if let label = request.stateLabel {
        Text(label).font(.caption).foregroundStyle(.secondary)
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .frame(maxWidth: 380, minHeight: 44, alignment: .leading)
    .background(Color.primary.opacity(0.07), in: .rect(cornerRadius: 14))
    .contentShape(.rect(cornerRadius: 14))
    .accessibilityElement(children: .combine)
  }
}

private struct CallRequestPendingView: View {
  @Environment(AppModel.self) private var model
  let request: CallRequest

  private var decision: CallRequestDecision { model.callRequestBoard.decision(for: request.id) }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .top, spacing: 10) {
        Image(systemName: "phone").foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 2) {
          Text("Wants to call for you").font(.caption).foregroundStyle(.secondary)
          Text(request.callee).font(.subheadline.weight(.medium)).textSelection(.enabled)
          Text(request.number).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
        }
      }
      Text(request.goal).font(.callout).textSelection(.enabled)
      Text(
        "Check that the opening says it's an AI assistant, whom it calls for, "
          + "that the call is transcribed, and why it calls."
      )
        .font(.caption)
        .foregroundStyle(.secondary)
      CallQuote(text: request.opening)
      if !decision.error.isEmpty {
        Text(decision.error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
      }
      HStack(spacing: 8) {
        Spacer(minLength: 0)
        if decision.sending { ProgressView().controlSize(.small) }
        Button("Decline") { model.declineCallRequest(request) }
        Button("Approve") { model.approveCallRequest(request) }
          .buttonStyle(.borderedProminent)
      }
      .disabled(decision.sending)
    }
    .padding(12)
    .frame(maxWidth: 380, alignment: .leading)
    .background(Color.primary.opacity(0.07), in: .rect(cornerRadius: 14))
  }
}

private struct CallQuote: View {
  let text: String

  var body: some View {
    HStack(spacing: 8) {
      Capsule().fill(.quaternary).frame(width: 2)
      Text(text).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
    }
    .fixedSize(horizontal: false, vertical: true)
  }
}

/// One outside call: its goal and the conversation, which grows while the call goes on.
struct CallSheet: View {
  @Environment(AppModel.self) private var model
  let call: OpenCall

  private var request: CallRequest { model.callRequestBoard.current(call.request) }
  private var calling: Bool { request.status == .calling }

  var body: some View {
    NavigationStack {
      ScrollView { content }
        .defaultScrollAnchor(.bottom)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button(role: .close) { model.closeCall() }
          }
          ToolbarItem(placement: .principal) { title }
        }
    }
    .task(id: call.id) { await model.watchOpenCall() }
  }

  private var title: some View {
    VStack(spacing: 2) {
      Text(request.callee).font(.headline).lineLimit(1)
      HStack(spacing: 6) {
        Text(request.number).monospaced()
        if let label = request.stateLabel { Text(label) }
      }
      .font(.caption)
      .foregroundStyle(.secondary)
      .lineLimit(1)
      .minimumScaleFactor(0.75)
    }
    .accessibilityElement(children: .combine)
  }

  private var content: some View {
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Goal").font(.caption).foregroundStyle(.secondary)
        Text(request.goal).textSelection(.enabled)
      }
      if request.outcome == .failed, let error = request.error?.nilIfEmpty {
        Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
      }
      line(speaker: botName, text: request.opening, bot: true)
      ForEach(call.lines) { item in
        line(speaker: item.speaker == .bot ? botName : request.callee, text: item.text, bot: item.speaker == .bot)
      }
      status
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var botName: String {
    model.agents.first { $0.id == request.agentID }?.name ?? "Bot"
  }

  @ViewBuilder private var status: some View {
    if call.failed {
      Text("Couldn't load the transcript.").font(.caption).foregroundStyle(.red)
    } else if !call.loaded {
      ProgressView().controlSize(.small).frame(maxWidth: .infinity)
    } else if calling {
      HStack(spacing: 6) {
        ProgressView().controlSize(.small)
        Text("On the call…").foregroundStyle(.secondary)
      }
      .accessibilityElement(children: .combine)
    } else if call.lines.isEmpty {
      Text("No transcript.").foregroundStyle(.secondary)
    }
  }

  private func line(speaker: String, text: String, bot: Bool) -> some View {
    VStack(alignment: bot ? .trailing : .leading, spacing: 4) {
      Text(speaker).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 6)
      Text(text)
        .textSelection(.enabled)
        .bubble(owner: bot)
        .frame(maxWidth: 520, alignment: bot ? .trailing : .leading)
    }
    .frame(maxWidth: .infinity, alignment: bot ? .trailing : .leading)
    .accessibilityElement(children: .combine)
  }
}
