import AppKit
import apfelkern
import SwiftUI

/// The steps of a provider sign-in running on the server. Links open only when the owner asks.
struct ProviderLoginView: View {
    @Environment(AppModel.self) private var model
    let login: ProviderLogin
    @State private var answer = ""

    private var sending: Bool { model.providerLoginRequests.contains(login.provider) }

    var body: some View {
        ForEach(Array(login.events.enumerated()), id: \.offset) { _, event in
            switch event {
            case let .info(message, links):
                VStack(alignment: .leading, spacing: 4) {
                    Text(message)
                    ForEach(links, id: \.url) { link in
                        Link(link.label ?? link.url.absoluteString, destination: link.url)
                    }
                }
            case let .authorization(url, instructions):
                authorization(url: url, instructions: instructions)
            case let .deviceCode(userCode, verificationURL, expiresIn):
                deviceCode(userCode, url: verificationURL, expiresIn: expiresIn)
            case .progress:
                EmptyView()
            }
        }
        if let prompt = login.prompt {
            promptView(prompt)
        }
        HStack {
            ProgressView().controlSize(.small)
            Text(progress).foregroundStyle(.secondary)
            Spacer()
            Button("Cancel Sign-In", role: .cancel) { model.cancelProviderLogin(login) }
                .disabled(sending)
        }
    }

    private var progress: String {
        for event in login.events.reversed() {
            if case let .progress(message) = event { return message }
        }
        return login.prompt == nil ? "Waiting for the provider…" : "Waiting for your answer…"
    }

    private func authorization(url: URL, instructions: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let instructions { Text(instructions) }
            HStack {
                Button("Open Sign-In Page") { NSWorkspace.shared.open(url) }
                Button("Copy Link") { copy(url.absoluteString) }
            }
        }
    }

    private func deviceCode(_ code: String, url: URL, expiresIn: TimeInterval?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Enter this code on the provider's page:")
            HStack {
                Text(code)
                    .font(.title2.monospaced())
                    .textSelection(.enabled)
                Button("Copy Code") { copy(code) }
            }
            Button("Open \(url.host() ?? url.absoluteString)") { NSWorkspace.shared.open(url) }
            if let expiresIn {
                let validity = Duration.seconds(expiresIn).formatted(.units(allowed: [.minutes, .seconds]))
                Text("The code is valid for \(validity).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func promptView(_ prompt: ProviderLogin.Prompt) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(prompt.message)
            switch prompt.kind {
            case .select:
                HStack {
                    ForEach(prompt.options, id: \.id) { option in
                        Button(option.label) { submit(prompt, value: option.id) }
                            .help(option.description ?? "")
                    }
                }
            case .secret:
                SecureField("Answer", text: $answer, prompt: prompt.placeholder.map(Text.init))
                    .onSubmit { submit(prompt, value: answer) }
                submitButton(prompt)
            case .text, .manualCode:
                TextField("Answer", text: $answer, prompt: prompt.placeholder.map(Text.init))
                    .onSubmit { submit(prompt, value: answer) }
                submitButton(prompt)
            }
        }
        .disabled(sending)
        .id(prompt.id)
    }

    private func submitButton(_ prompt: ProviderLogin.Prompt) -> some View {
        Button("Continue") { submit(prompt, value: answer) }
            .keyboardShortcut(.defaultAction)
            .disabled(answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private func submit(_ prompt: ProviderLogin.Prompt, value: String) {
        let value = prompt.kind == .select ? value : value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        model.answerProviderLogin(login, promptID: prompt.id, value: value)
        answer = ""
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
