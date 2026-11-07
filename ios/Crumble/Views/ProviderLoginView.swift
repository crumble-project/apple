import apfelkern
import AuthenticationServices
import SwiftUI

/// The steps of a provider sign-in running on the server, as rows of a form. Links open only when the
/// owner asks, in the system sign-in sheet. The server finishes the sign-in, so the sheet returns
/// nothing to the app and closes when the sign-in ends.
struct ProviderLoginView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.webAuthenticationSession) private var webAuthenticationSession
  @Environment(\.openURL) private var openURL
  let login: ProviderLogin
  @State private var answer = ""
  @State private var browserURL: URL?

  private var sending: Bool { model.providerLoginRequests.contains(login.provider) }

  var body: some View {
    ForEach(Array(login.events.enumerated()), id: \.offset) { _, event in
      switch event {
      case let .info(message, links):
        Text(message)
        ForEach(links, id: \.url) { link in
          Link(link.label ?? link.url.absoluteString, destination: link.url)
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
      ProgressView()
      Text(login.progressText).foregroundStyle(.secondary)
    }
    .task(id: browserURL) { await showBrowser() }
    Button("Cancel Sign-In", role: .cancel) { model.cancelProviderLogin(login) }
      .disabled(sending)
  }

  /// Leaving this view cancels the task, which closes the sheet once the sign-in ends.
  private func showBrowser() async {
    guard let browserURL else { return }
    _ = try? await webAuthenticationSession.authenticate(
      using: browserURL, callbackURLScheme: AppModel.oauthCallbackScheme)
    if !Task.isCancelled { self.browserURL = nil }
  }

  @ViewBuilder
  private func authorization(url: URL, instructions: String?) -> some View {
    if let instructions { Text(instructions) }
    Button("Open Sign-In Page") { browserURL = url }
    // The sign-in sheet has no address bar, and a pasted answer can be the address the browser ended on.
    Button("Open in Safari") { openURL(url) }
    Button("Copy Link") { UIPasteboard.general.string = url.absoluteString }
  }

  @ViewBuilder
  private func deviceCode(_ code: String, url: URL, expiresIn: TimeInterval?) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Enter this code on the provider's page:")
      Text(code)
        .font(.title2.monospaced())
        .textSelection(.enabled)
      if let expiresIn {
        let validity = Duration.seconds(expiresIn).formatted(.units(allowed: [.minutes, .seconds]))
        Text("The code is valid for \(validity).")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
    Button("Copy Code") { UIPasteboard.general.string = code }
    Button("Open \(url.host() ?? url.absoluteString)") { browserURL = url }
  }

  @ViewBuilder
  private func promptView(_ prompt: ProviderLogin.Prompt) -> some View {
    Group {
      switch prompt.kind {
      case .select:
        Text(prompt.message)
        ForEach(prompt.options, id: \.id) { option in
          Button { submit(prompt, value: option.id) } label: {
            VStack(alignment: .leading, spacing: 2) {
              Text(option.label)
              if let description = option.description {
                Text(description).font(.caption).foregroundStyle(.secondary)
              }
            }
          }
        }
      case .secret:
        Text(prompt.message)
        SecureField("Answer", text: $answer, prompt: prompt.placeholder.map(Text.init))
          .onSubmit { submit(prompt, value: answer) }
          .accessibilityIdentifier("providerLoginAnswer")
        submitButton(prompt)
      case .text, .manualCode:
        Text(prompt.message)
        TextField("Answer", text: $answer, prompt: prompt.placeholder.map(Text.init))
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .onSubmit { submit(prompt, value: answer) }
          .accessibilityIdentifier("providerLoginAnswer")
        submitButton(prompt)
      }
    }
    .disabled(sending)
  }

  private func submitButton(_ prompt: ProviderLogin.Prompt) -> some View {
    Button("Continue") { submit(prompt, value: answer) }
      .disabled(!canSubmit(prompt, value: answer))
  }

  /// A text prompt can be optional: GitHub Copilot takes a blank domain to mean github.com.
  private func canSubmit(_ prompt: ProviderLogin.Prompt, value: String) -> Bool {
    prompt.kind == .text || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private func submit(_ prompt: ProviderLogin.Prompt, value: String) {
    guard canSubmit(prompt, value: value) else { return }
    let value = prompt.kind == .select ? value : value.trimmingCharacters(in: .whitespacesAndNewlines)
    model.answerProviderLogin(login, promptID: prompt.id, value: value)
    answer = ""
  }
}
