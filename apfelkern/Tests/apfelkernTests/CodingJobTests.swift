import Foundation
import Testing

@testable import apfelkern

private func decode(_ json: String) throws -> Message {
  try JSONDecoder().decode(Message.self, from: Data(json.utf8))
}

@Test func codingToolResultDecodesJob() throws {
  let message = try decode(
    #"{"id":"m1","role":"toolResult","toolName":"coding","#
      + #""toolDetails":{"name":"fix-login","status":"working","conversationId":"c1"}}"#)
  #expect(CodingJob(message: message) == CodingJob(name: "fix-login", conversationId: "c1", status: "working"))
  #expect(CodingJob(message: message)?.isWorking == true)
}

@Test func codingStatusListingIsNotAJob() throws {
  let message = try decode(#"{"id":"m1","role":"toolResult","toolName":"coding","content":"none"}"#)
  #expect(CodingJob(message: message) == nil)
}

@Test func codingOriginHasLabel() throws {
  let message = try decode(
    #"{"id":"m1","role":"user","content":"Done","origin":{"kind":"coding","name":"fix-login"}}"#)
  #expect(messageLabel(message) == "Coding job · fix-login")
}

@Test func jobHistoryDecodesProjectedSteps() throws {
  let json = #"{"kind":"step","id":"t1","tool":"bash","label":"Ran","icon":"terminal","subject":"swift test","#
    + #""result":{"id":"r","entryId":"e","role":"toolResult","content":"boom","isError":true}}"#
  let item = try JSONDecoder().decode(CodingJobItem.self, from: Data(json.utf8))
  guard case .tool(let tool) = item else { Issue.record("expected a step"); return }
  #expect(tool.subject == "swift test" && tool.output == "boom" && tool.isError && tool.finished)
}

@Test func shownOutputKeepsEveryLine() {
  func tool(_ output: String) -> CodingJobItem.Tool {
    CodingJobItem.Tool(id: "t", name: "bash", subject: "", output: output, isError: false, finished: true)
  }
  let lines = (1...500).map(String.init).joined(separator: "\n")
  #expect(tool(lines + "\n\n").shownOutput == lines)
  #expect(tool("\n").shownOutput == "No output.")
}

@Test func draftDefaultsCodingOff() {
  #expect(AgentDraft(isNew: true, agentID: "").toolsCoding == false)
}

@Test func jobQuestionEventDecodes() throws {
  let message = try decode(
    #"{"id":"m1","role":"event","kind":"job-question","content":"Which DB?","#
      + #""jobQuestion":{"id":"q1","kind":"coding","job":"fix-login"}}"#)
  #expect(message.jobQuestion == JobQuestionEvent(id: "q1", kind: "coding", job: "fix-login"))
}

@Test func answerListsPickedOptionsInOrderThenWrittenText() {
  let question = JobQuestion(id: "q", text: "Which?", options: ["a", "b", "c"], multiple: true)
  var answer = JobAnswer()
  #expect(answer.reply(to: question).isEmpty)
  answer.picked = ["c", "a"]
  answer.text = "  also d\n"
  #expect(answer.reply(to: question) == "a, c\nalso d")
}

@Test func jobSummaryNamesTheModelAndLeavesOutZeroCost() {
  let usage = JobUsage(inputTokens: 1000, outputTokens: 500, cachedTokens: 0, cost: 0)
  let job = Job(kind: .coding, name: "fix", status: "idle", usage: usage, model: "gpt-6")
  #expect(job.summary(locale: Locale(identifier: "en_US")) == "gpt-6 · 1,000 in · 500 out")
  #expect(Job(kind: .coding, name: "fix", status: "idle").summary().isEmpty)
}

@Test func transcriptFencesOutputLongerThanItsBackticks() throws {
  let call = #"{"type":"toolCall","id":"t1","name":"read","arguments":{"path":"a/b"}}"#
  let messages = try [
    decode(#"{"id":"u","role":"user","content":"Fix it"}"#),
    decode(#"{"id":"a","role":"assistant","blocks":[{"type":"text","text":"Reading."},"# + call + "]}"),
    decode(#"{"id":"r","role":"toolResult","toolCallId":"t1","content":"````x","isError":true}"#)
  ]
  let transcript = JobTranscript(kind: .coding, name: "fix", messages: messages)
  #expect(transcript.filename == "fix.md")
  #expect(transcript.markdown == """
    # fix

    Coding job

    ## Task

    Fix it

    Reading.

    ### read

    ```json
    {
      "path" : "a/b"
    }
    ```

    Failed:

    `````
    ````x
    `````

    """)
}
