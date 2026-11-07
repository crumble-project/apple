import Foundation

extension GroupChatHost {
  public func createGroup() {
    groupDraft = GroupDraft()
  }

  public func editGroup(_ group: GroupChat) {
    groupDraft = GroupDraft(groupID: group.id, name: group.name, memberIDs: group.memberIds)
  }

  /// Shows a new group at once under a provisional ID and swaps in the server's when it confirms.
  public func saveGroup(_ draft: GroupDraft) {
    guard draft.isValid else { return }
    groupDraft = nil
    if let id = draft.groupID {
      updateGroup(id, draft: draft)
    } else {
      addGroup(draft)
    }
  }

  private func addGroup(_ draft: GroupDraft) {
    let name = draft.trimmedName
    let members = draft.memberIDs
    let provisional = "local:" + newRequestID()
    let now = ISO8601DateFormatter().string(from: Date())
    let routeAtStart = route
    optimisticMutation(
      key: "group:\(provisional)",
      update: { [self] in
        groupChats.append(
          GroupChat(id: provisional, name: name, memberIds: members, createdAt: now, updatedAt: now))
      },
      rollback: { [self] in
        groupChats.removeAll { $0.id == provisional }
        if groupDraft == nil { groupDraft = draft }
      },
      work: { client in
        let created = try await client.createGroupChat(name: name, memberIDs: members)
        return { [self] in
          groupChats.removeAll { $0.id == provisional || $0.id == created.id }
          groupChats.append(created)
          // Open the new group only if the owner is still where they were; a late response must not
          // take them away from a chat they moved to meanwhile, or clear what they typed there.
          if route == routeAtStart { selectGroup(created.id) }
        }
      })
  }

  private func updateGroup(_ id: String, draft: GroupDraft) {
    guard let previous = groupChats.first(where: { $0.id == id }) else { return }
    let name = draft.trimmedName
    let members = draft.memberIDs
    optimisticMutation(
      key: "group:\(id)",
      update: { [self] in
        if let index = groupChats.firstIndex(where: { $0.id == id }) {
          groupChats[index].name = name
          groupChats[index].memberIds = members
        }
      },
      rollback: { [self] in
        if let index = groupChats.firstIndex(where: { $0.id == id }) { groupChats[index] = previous }
        if groupDraft == nil { groupDraft = draft }
      },
      work: { client in
        let updated = try await client.updateGroupChat(id, name: name, memberIDs: members)
        return { [self] in
          if let index = groupChats.firstIndex(where: { $0.id == id }) { groupChats[index] = updated }
        }
      })
  }

  public func deleteGroup(_ id: String) {
    guard let index = groupChats.firstIndex(where: { $0.id == id }) else { return }
    let removed = groupChats[index]
    let wasOpen = selectedGroupID == id
    optimisticMutation(
      key: "group:\(id)",
      update: { [self] in
        groupChats.removeAll { $0.id == id }
        if wasOpen {
          leaveGroup()
          route = nil
          messages = []
        }
      },
      rollback: { [self] in
        if !groupChats.contains(where: { $0.id == id }) {
          groupChats.insert(removed, at: min(index, groupChats.count))
        }
        if wasOpen, route == nil { selectGroup(id) }
      },
      work: { client in
        try await client.deleteGroupChat(id)
        return { [self] in composerDrafts[GroupChat.deliveryKey(id)] = nil }
      })
  }
}
