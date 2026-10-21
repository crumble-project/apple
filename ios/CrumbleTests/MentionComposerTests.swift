import apfelkern
import Foundation
import Testing

@testable import Crumble

struct MentionComposerTests {
  @Test func mentionQueryFindsNamesWithoutTreatingEmailAddressesAsMentions() {
    let multiword = "Ask @Research Buddy"
    let multiwordMatch = mentionQuery(
      in: multiword, selection: NSRange(location: (multiword as NSString).length, length: 0))
    #expect(multiwordMatch?.query == "Research Buddy")
    #expect(multiwordMatch?.range == NSRange(location: 4, length: 15))

    let unicode = "Ask @Zoë"
    let unicodeMatch = mentionQuery(
      in: unicode, selection: NSRange(location: (unicode as NSString).length, length: 0))
    #expect(unicodeMatch?.query == "Zoë")
    #expect(unicodeMatch?.range == NSRange(location: 4, length: 4))

    let email = "mail me@example.com"
    #expect(
      mentionQuery(in: email, selection: NSRange(location: (email as NSString).length, length: 0))
        == nil)
    #expect(mentionQuery(in: multiword, selection: NSRange(location: 7, length: 0))?.query == "Re")
    #expect(mentionQuery(in: multiword, selection: NSRange(location: 3, length: 1)) == nil)
  }
}
