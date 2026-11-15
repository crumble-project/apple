import Foundation
import Testing
@testable import apfelkern

struct ChatFilesTests {
    @Test func transcriptFilesKeepTheirIDsAndDeletedMarkers() throws {
        let wire = try JSONDecoder().decode(Components.Schemas.TranscriptMessage.self, from: Data(#"""
            {"id":"a1:5:0","entryId":"a1:5","role":"user","content":"","replyReferences":[],
             "files":[{"id":"f1","name":"dot.png","mimeType":"image/png","size":70},
                      {"id":"f2","name":"notes.txt","mimeType":"text/plain","size":5},
                      {"id":"f3","deleted":true}]}
            """#.utf8))
        let files = try Message(wire: wire).attachments ?? []
        #expect(files.map(\.id) == ["f1", "f2", "f3"])
        #expect(files.map(\.isImage) == [true, false, false])
        #expect(files.map(\.deleted) == [false, false, true])
        #expect(files[0] == AttachmentInfo(id: "f1", name: "dot.png", mimeType: "image/png", size: 70))
    }

    @Test func aDeletionReachesEveryReferenceInItsChatOnly() {
        let live = AttachmentInfo(id: "f1", name: "dot.png", mimeType: "image/png", size: 1)
        let older = Message(id: "a1:1:0", entryId: "a1:1", role: "user", attachments: [live])
        let newer = Message(id: "a1:2:0", entryId: "a1:2", role: "user", attachments: [.deleted("f1")])
        var deleted = DeletedFiles()
        let reconciled = deleted.reconcile([older, newer], chat: "a1")
        #expect(reconciled.map { $0.attachments?.first?.deleted } == [true, true])
        #expect(reconciled.first?.attachments?.first?.isImage == false)
        // A page loaded later that still lists the file follows the deletion too.
        #expect(deleted.reconcile([older], chat: "a1").first?.attachments?.first?.deleted == true)
        #expect(deleted.reconcile([older], chat: "a2").first?.attachments?.first?.deleted == false)
        deleted.removeAll()
        #expect(!deleted.contains("f1", chat: "a1"))
    }
}
