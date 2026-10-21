# Contract 1.3.0

- Accept `attachments` on group messages, which may then have empty content, and add `GET /v1/group-chats/{id}/attachments/{entryId}/{index}`. Group messages list their attachments in `attachments`.
- Add optional `groupId` and `groupName` to `ReplyEvent` for bot answers in group chats.
- Add `source` to `Memory`: a `MemorySource` naming the chat, owner, scheduled task, bot, or group chat a memory was saved from, or `null` for memories saved before sources were recorded.
- Export `group-chat-snapshot.schema.json`, the JSON Schema of each `snapshot` event on the group chat stream, so clients can generate and validate group snapshots as they do bot chat snapshots.
