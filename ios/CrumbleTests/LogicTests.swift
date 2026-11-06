import apfelkern
import Foundation
import ImageIO
import Testing
import UIKit
import UniformTypeIdentifiers

@testable import Crumble

struct LogicTests {
  @MainActor @Test func sidebarPreviewsUpdateWithoutOpeningTheBotChat() throws {
    let model = AppModel(client: APIClient(baseURL: "http://127.0.0.1:1", token: ""))
    model.agents = [
      Agent(id: "a1", name: "Atlas", lastMessage: "Earlier"), Agent(id: "a2", name: "Beacon")
    ]
    model.route = .memory
    let event = try JSONDecoder().decode(
      ActivityEvent.self,
      from: Data(
        #"{"type":"chat-preview","agentId":"a2","agentName":"Beacon","lastMessage":"A new reply from Beacon"}"#
          .utf8))
    model.handleActivity(event)
    #expect(model.agents[0].lastMessage == "Earlier")
    #expect(model.agents[1].lastMessage == "A new reply from Beacon")
    #expect(model.route == .memory)
    #expect(model.messages.isEmpty)
    #expect(notification(for: event, in: NotificationContext(appActive: false, route: nil)) == nil)
    model.handleActivity(
      ActivityEvent(type: "chat-preview", agentId: "a2", agentName: "Beacon", lastMessage: ""))
    #expect(model.agents[1].lastMessage?.isEmpty == true)
    #expect(model.unread.total == 0)
    model.handleActivity(ActivityEvent(type: "reply", agentId: "a2", agentName: "Beacon", origin: "chat", preview: "Hi"))
    #expect(model.unread.total == 1)
    model.handleActivity(ActivityEvent(type: "reply", agentId: "a2", agentName: "Beacon", origin: "bot", preview: "Hi"))
    #expect(model.unread.total == 1)
  }

  @Test func sseRejectsSnapshotsWithoutAgent() throws {
    var parser = SSEParser()
    _ = try parser.feed("event: snapshot")
    _ = try parser.feed("data: {\"status\":\"idle\"}")
    #expect(throws: SSEParser.InvalidPayload.self) { try parser.feed("") }
  }

  @Test func mergeKeepsLoadedHistoryInEntryOrder() {
    let older = [Message(id: "a1:2:0", role: "user"), Message(id: "a1:10:0", role: "assistant")]
    let snapshot = [
      Message(id: "a1:10:0", role: "assistant", content: .string("updated")),
      Message(id: "a1:11:1", role: "user"), Message(id: "a1:11:0", role: "user")
    ]
    let merged = mergeMessages(older, snapshot)
    #expect(merged.map(\.id) == ["a1:2:0", "a1:10:0", "a1:11:0", "a1:11:1"])
    #expect(merged[1].text == "updated")
  }

  @Test func automationRunAtPreservesExplicitOffsetInstant() throws {
    #expect(automationRunDate("2026-10-18T12:10:00+02:00") == automationRunDate("2026-10-18T10:10:00Z"))
    let fractional = try #require(automationRunDate("2026-10-18T12:10:00.123Z"))
    let whole = try #require(automationRunDate("2026-10-18T12:10:00Z"))
    #expect(abs(fractional.timeIntervalSince(whole) - 0.123) < 0.000001)
  }

  @Test func requestIDsAreUUIDs() {
    let id = newRequestID()
    #expect(UUID(uuidString: id) != nil)
    #expect(id.split(separator: "-").count == 5)
  }

  @Test func chatHidesToolActivity() {
    let tool = Message(
      id: "a1:1:0", role: "assistant", blocks: .array([.object(["type": .string("toolCall")])]))
    let reply = Message(
      id: "a1:1:1", role: "assistant", content: .string("Hi"),
      blocks: .array([.object(["type": .string("text"), "text": .string("Hi")])]))
    #expect(!shownInChat(tool))
    #expect(shownInChat(reply))
  }

  @Test func shiftReturnInsertsANewlineAtTheCaret() throws {
    let text = "hello world"
    let caret = text.index(text.startIndex, offsetBy: 5)
    let (edited, after) = insertingNewline(into: text, replacing: caret..<caret)
    #expect(edited == "hello\n world")
    #expect(edited[after...] == " world")
    let word = try #require(text.range(of: "world"))
    #expect(insertingNewline(into: text, replacing: word).text == "hello \n")
    #expect(insertingNewline(into: text, replacing: nil).text == "hello world\n")
  }

  @Test func filesBecomeAttachmentsTheServerAccepts() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let notes = folder.appending(path: "notes.md")
    try Data("# Groceries".utf8).write(to: notes)
    let text = try loadAttachment(from: notes)
    #expect(text.mimeType.hasPrefix("text/") && text.data == Data("# Groceries".utf8))

    let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
      UIColor.red.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
    }
    let tiff = folder.appending(path: "photo.tiff")
    let destination = CGImageDestinationCreateWithURL(
      tiff as CFURL, UTType.tiff.identifier as CFString, 1, nil)
    let imageDestination = try #require(destination)
    let cgImage = try #require(image.cgImage)
    CGImageDestinationAddImage(imageDestination, cgImage, nil)
    #expect(CGImageDestinationFinalize(imageDestination))
    let converted = try loadAttachment(from: tiff)
    #expect(converted.mimeType == "image/jpeg" && converted.name == "photo.jpg")

    // A valid 2×2 24-bit BMP exercises the unsupported-image conversion path.
    let bmp = folder.appending(path: "photo.bmp")
    var bytes: [UInt8] = [
      66, 77, 70, 0, 0, 0, 0, 0, 0, 0, 54, 0, 0, 0, 40, 0, 0, 0, 2, 0, 0, 0, 2, 0, 0, 0, 1, 0, 24,
      0, 0, 0, 0, 0, 16, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
    ]
    bytes += [0, 0, 255, 0, 255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 0]
    try Data(bytes).write(to: bmp)
    let convertedBMP = try loadAttachment(from: bmp)
    #expect(convertedBMP.mimeType == "image/jpeg" && convertedBMP.name == "photo.jpg")
    let pdf = folder.appending(path: "doc.pdf")
    try Data("%PDF-1.4".utf8).write(to: pdf)
    #expect(throws: AttachmentError.self) { try loadAttachment(from: pdf) }
  }

  @Test func notificationsSkipWhatIsOnScreen() {
    let reply = ActivityEvent(
      type: "reply", agentId: "a1", agentName: "Atlas", origin: "owner",
      preview: "**Done**, two meetings.")
    #expect(
      notification(for: reply, in: NotificationContext(appActive: false, route: .agent("a1")))?.body
        == "Done, two meetings.")
    #expect(
      notification(for: reply, in: NotificationContext(appActive: true, route: .agent("a1"))) == nil
    )
    #expect(
      notification(for: reply, in: NotificationContext(appActive: true, route: .agent("a2")))?.title
        == "Atlas")
    var delegated = reply
    delegated.origin = "bot"
    #expect(
      notification(for: delegated, in: NotificationContext(appActive: false, route: nil)) == nil)
  }

  @Test func activityStreamPassesOnlyActivity() throws {
    var parser = SSEParser(accepting: ["activity"])
    _ = try parser.feed("event: heartbeat")
    _ = try parser.feed("data: {}")
    #expect(try parser.feed("") == nil)
    _ = try parser.feed("event: activity")
    let reply = Components.Schemas.ReplyEvent(
      agentId: "a1", agentName: "Atlas", createdAt: ContractFixtures.timestamp,
      eventId: "event-1", origin: "user", preview: "Reply", serverId: "server-a", _type: .reply)
    _ = try parser.feed("data: \(ContractFixtures.json(reply))")
    #expect(try parser.feed("") != nil)
  }

  @Test func botCommunicationEventRetainsAttributionAndAppearsInChat() throws {
    let data = Data(
      #"""
      {"id":"exchange-1","role":"event","kind":"bot-message","content":"I asked how Bot2 feels.",
      "communication":{"executionId":"run-1","fromAgentId":"a1","fromName":"Atlas",
      "toAgentId":"a2","toName":"Beacon","status":"done"}}
      """#
        .utf8)
    let message = try JSONDecoder().decode(Message.self, from: data)
    let rows = ChatRow.rows(messages: [message], snapshot: nil, hasMore: false)
    #expect(rows.count == 1)
    guard case .message(let retained, _) = rows[0] else {
      Issue.record("bot communication event was omitted")
      return
    }
    #expect(retained.kind == "bot-message")
    #expect(retained.communication?.fromName == "Atlas")
    #expect(retained.communication?.toName == "Beacon")
    #expect(retained.communication?.status == "done")
  }

  @Test func signInCallbacksCarryACodeOrAReason() throws {
    let result = try oauthResult(
      from: URL(string: "dev.crumble.ios:/oauth/callback?code=abc&state=xyz")!)
    #expect(result.code == "abc" && result.state == "xyz" && result.iss == nil)
    let issued = try oauthResult(
      from: URL(
        string:
          "dev.crumble.ios:/oauth/callback?code=abc&state=xyz&iss=https%3A%2F%2Fexecutor.sh%2Fapi%2Fauth"
      )!)
    #expect(issued.iss == "https://executor.sh/api/auth")
    #expect(throws: SignInError.self) {
      try oauthResult(
        from: URL(
          string:
            "dev.crumble.ios:/oauth/callback?error=access_denied&error_description=User%20declined")!
      )
    }
    #expect(throws: SignInError.self) {
      try oauthResult(from: URL(string: "dev.crumble.ios:/oauth/callback")!)
    }
  }

  @Test func markdownSplitsBlocks() {
    let blocks = MarkdownBlock.parse(
      "Two meetings:\n\n- 09:00 Design\n- 14:30 Call\n\n```\ncode\n```")
    #expect(
      blocks == [
        .paragraph("Two meetings:"),
        .list([
          .init(marker: "•", text: "09:00 Design", indent: 0),
          .init(marker: "•", text: "14:30 Call", indent: 0)
        ]), .code("code")
      ])
  }
}

/// UIKit has no public way to make a key press.
private final class StubKey: UIKey {
  override var keyCode: UIKeyboardHIDUsage { .keyboardReturnOrEnter }
  override var modifierFlags: UIKeyModifierFlags { [] }
}

private final class StubPress: UIPress {
  override var key: UIKey? { StubKey() }
}

struct PhoneNavigationTests {
  private let chat = PhonePage.route(.agent("a"))

  @Test func aChatOpensFromTheList() {
    #expect(PhonePage.path(from: [], to: .agent("a")) == [chat])
  }

  @Test func aPageFromAChatReturnsToIt() {
    #expect(PhonePage.path(from: [chat], to: .providers) == [chat, .route(.providers)])
  }

  @Test func aPageFromNowhereReturnsThroughSettings() {
    #expect(PhonePage.path(from: [], to: .memory) == [.settings, .route(.memory)])
  }

  @Test func oneSettingsPageReplacesAnother() {
    #expect(PhonePage.path(from: [.settings, .route(.memory)], to: .skills) == [.settings, .route(.skills)])
  }

  @Test func aChatReplacesWhateverWasOpen() {
    #expect(PhonePage.path(from: [.settings, .route(.memory)], to: .agent("a")) == [chat])
  }

  @Test func leavingARouteKeepsSettingsOpen() {
    #expect(PhonePage.path(from: [.settings], to: nil) == [.settings])
    #expect(PhonePage.path(from: [chat], to: nil).isEmpty)
  }

  @Test func aRunEndsWhereTheSenderChanges() {
    let places = BubblePlace.places(["a", "a", nil, "a", "b"]) { $0 }
    #expect(places.map(\.startsRun) == [true, false, true, true, true])
    #expect(places.map(\.endsRun) == [false, true, true, true, true])
  }
}

@MainActor
struct ComposerTextViewTests {
  private func composing() -> PastingTextView {
    let view = PastingTextView()
    view.setMarkedText("nihon", selectedRange: NSRange(location: 5, length: 0))
    return view
  }

  @Test func returnSendsWhenNothingIsComposing() {
    let view = PastingTextView()
    var keys: [ComposerKey] = []
    view.onKey = {
      keys.append($0)
      return true
    }
    view.pressesBegan([StubPress()], with: nil)
    #expect(keys == [.send])
  }

  @Test func returnConfirmsACompositionInsteadOfSending() {
    let view = composing()
    #expect(view.markedTextRange != nil)
    var keys: [ComposerKey] = []
    view.onKey = {
      keys.append($0)
      return true
    }
    view.pressesBegan([StubPress()], with: nil)
    #expect(keys.isEmpty)
  }

  @Test func emptyingTheDraftEndsAComposition() {
    let view = composing()
    view.show("", selection: nil)
    #expect(view.markedTextRange == nil)
    #expect(view.text.isEmpty)
  }

  @Test func anUpdateLeavesACompositionAlone() {
    let view = composing()
    view.show("nihon", selection: nil)
    #expect(view.markedTextRange != nil)
  }
}
