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
        case .declined: CallRequestRow(request: live)
        case .calling, .ended: CallRequestRow(request: live, detail: failure(of: live))
        }
    }

    private func failure(of request: CallRequest) -> String? {
        request.outcome == .failed ? request.error : nil
    }
}

/// A call request or outside call that has settled, as one line; once placed, it opens the call.
struct CallRequestRow: View {
    @Environment(AppModel.self) private var model
    let request: CallRequest
    var detail: String?

    var body: some View {
        if request.status == .declined {
            content
        } else {
            Button {
                model.openCall(request)
            } label: {
                content.contentShape(.rect(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .help("Open call")
            .accessibilityHint("Opens the call")
        }
    }

    private var content: some View {
        HStack(spacing: 10) {
            if request.status == .calling {
                ProgressView().controlSize(.small).frame(width: 16)
            } else {
                Image(systemName: "phone").font(.system(size: 13)).foregroundStyle(.secondary).frame(width: 16)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(request.callee).font(.system(size: 14, weight: .medium)).lineLimit(1)
                if let detail = detail?.nilIfEmpty {
                    Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 16)
            if let label = request.stateLabel {
                Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 380, alignment: .leading)
        .background(Palette.bubble, in: .rect(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }
}

/// An outside call's end notice, drawn as its call request's row.
struct CallNoticeRow: View {
    let request: CallRequest
    let message: Message

    var body: some View {
        let detail = callNoticeDetail(message, request: request)
        HStack {
            CallRequestRow(request: request, detail: detail.prefix(1).uppercased() + detail.dropFirst())
            Spacer(minLength: 56)
        }
    }
}

private struct CallRequestPendingView: View {
    @Environment(AppModel.self) private var model
    let request: CallRequest

    private var decision: CallRequestDecision { model.callRequestBoard.decision(for: request.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Text(request.goal).font(.system(size: 13)).textSelection(.enabled)
            VStack(alignment: .leading, spacing: 6) {
                Text(
                    "Check that the opening says it's an AI assistant, whom it calls for, "
                        + "that the call is transcribed, and why it calls."
                )
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text(request.opening)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) {
                        Capsule().fill(.quaternary).frame(width: 3)
                    }
            }
            if !decision.error.isEmpty {
                Text(decision.error).font(.system(size: 12)).foregroundStyle(.red).textSelection(.enabled)
            }
            buttons
        }
        .padding(12)
        .frame(maxWidth: 380, alignment: .leading)
        .background(Palette.bubble, in: .rect(cornerRadius: 14))
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "phone").font(.system(size: 13)).foregroundStyle(.secondary).frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text("Wants to call for you").font(.system(size: 12)).foregroundStyle(.secondary)
                Text(request.callee).font(.system(size: 14, weight: .medium)).lineLimit(1)
                Text(request.number).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
            }
        }
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            if decision.sending { ProgressView().controlSize(.small) }
            Button("Decline") { model.declineCallRequest(request) }
            Button("Approve") { model.approveCallRequest(request) }
                .buttonStyle(.borderedProminent)
        }
        .disabled(decision.sending)
    }
}

/// An outside call beside the chat, laid out like the details panel it replaces: who was called, the
/// goal, then what was said in the chat's own bubbles, live while it goes on. The toolbar closes it.
struct CallSheet: View {
    @Environment(AppModel.self) private var model
    let call: OpenCall
    let botName: String

    private var request: CallRequest { model.callRequestBoard.current(call.request) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                section("Goal") {
                    Text(request.goal)
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .card()
                }
                if request.outcome == .failed, let error = request.error?.nilIfEmpty {
                    Text(error).font(.system(size: 13)).foregroundStyle(.red).textSelection(.enabled)
                }
                section("Transcript") { conversation }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .task(id: call.opening) { await model.watchCallTranscript() }
    }

    private var header: some View {
        VStack(spacing: 6) {
            Image(systemName: "phone.fill")
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
                .frame(width: 56, height: 56)
                .background(Palette.bubble, in: .circle)
                .padding(.bottom, 4)
            Text(request.callee).font(.system(size: 17, weight: .semibold)).multilineTextAlignment(.center)
            Text([request.number, request.stateLabel ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding(.top, 28)
        .frame(maxWidth: .infinity)
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
            content()
        }
    }

    private var conversation: some View {
        let lines = [CallLineRow(id: "opening", mine: true, text: request.opening)]
            + call.lines.map { CallLineRow(id: "\($0.id)", mine: $0.speaker == .bot, text: $0.text) }
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(lines.enumerated()), id: \.element.id) { index, item in
                // As in Messages, a name only where the speaker changes.
                let turn = index == 0 || lines[index - 1].mine != item.mine
                line(speaker: turn ? (item.mine ? botName : request.callee) : nil, text: item.text, mine: item.mine)
                    .padding(.top, turn && index > 0 ? 10 : 0)
            }
            if call.failed {
                Text("Couldn’t load the transcript.").font(.system(size: 13)).foregroundStyle(.secondary)
            } else if !call.loaded {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity)
            } else if call.lines.isEmpty && request.status != .calling {
                Text("No transcript.").font(.system(size: 13)).foregroundStyle(.secondary)
            }
            if request.status == .calling {
                Text("On the call…").font(.system(size: 13)).foregroundStyle(.secondary)
            }
        }
    }

    private func line(speaker: String?, text: String, mine: Bool) -> some View {
        VStack(alignment: mine ? .trailing : .leading, spacing: 3) {
            if let speaker {
                Text(speaker).font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 6)
            }
            Text(text)
                .font(Palette.messageFont)
                .lineSpacing(Palette.messageLineSpacing)
                .textSelection(.enabled)
                .bubble(owner: mine)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(mine ? .leading : .trailing, 40)
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
    }
}

private struct CallLineRow {
    let id: String
    let mine: Bool
    let text: String
}
