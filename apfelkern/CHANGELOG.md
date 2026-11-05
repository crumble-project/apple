# Changelog

## Unreleased

- Add `BotSkill` and `BotSkillBoard`, which holds each bot's own skills and applies creates, edits, pins, and deletes at once, rolling back on failure and ignoring reads that predate a write. `APIClient` gains `botSkills`, `createBotSkill`, `updateBotSkill`, `setBotSkillPinned`, `deleteBotSkill`, and `assignSharedSkill`.
- Add `BotSecret`, `BotSecretDraft`, and `BotSecretBoard`, which holds each bot's credentials and logins, the sheet that edits one, and the requests the selected bot's chat shows, and polls while a card waits. `APIClient` gains `botSecrets`, `deleteBotSecret`, `declineBotSecret`, `botSecretUses`, and `passwordManagers`; the board saves through it. A save shows in the list at once and a failed one comes back as the draft with `saveError`, after any open sheet closes. A save with a new password manager reference waits on the sheet instead: `isSaving` holds it, and `closeDraft()` does nothing until the server answers. `closeDraft()` and a successful save clear typed values, and drafts redact them from `description` and `dump`. `BotSecretAsk` reads a `request_credential` or `request_login` result. `messageLabel` names a credential's notice. Test `withClient` now cancels its tasks instead of invalidating the session, and `resetDropsAResponseFromTheOldConnection` waits for its request, since both crashed the test run when a board's read started after a test ended.
- Add `BotRequest` and `BotRequestBoard`, which holds the selected bot's bot requests and the owner's decisions on them and polls while a card waits. `APIClient` gains `botRequests` and `declineBotRequest`; the board approves through it, keeping proposal fields the editor doesn't show. A request reads as decided only after the server confirms it. `AgentDraft` gains `init(agent:)`, `init(botRequest:)`, `botRequest`, and `canApprove`.
- Add `HeldActionBoard`, which holds the selected bot's held actions and the owner's decisions on them, and polls while a card depends on it. `Message.heldAction` carries the `held-action` event, and `APIClient` gains `heldActions`, `approveHeldAction`, and `declineHeldAction`. An action reads as decided only after the server confirms it.
- Add `GroupChatHost`, moved from the macOS and iOS apps. An app model conforms by exposing its conversation state and gets group chat loading, streaming, sending, retry, and optimistic create, update, and delete.
- Add `BotDesktopSession.settle()`, which returns when no control request waits for the server, so iOS can hold a background task until a hand-back lands.
- Add `ProviderLoginBoard`, moved from the macOS app so iOS shares it. It follows provider sign-ins on the server and reports what the app shows through its `onEvent` closure. Add `ProviderLogin.progressText`.
- Add `JobBoard`, which holds the selected bot's jobs, its open job, and answers to job questions, and polls while an open job or question depends on it. `JobKind`, `Job`, `JobHistory`, and `usageLine` move here from the macOS app so iOS shares them.
- Add `APIClient.answerCodingJob`, `jobs(_:agentID:)`, `jobHistory`, and `fullJobHistory`, plus `JobQuestion`, `JobQuestionEvent`, `Message.jobQuestion`, `JobAnswer`, and `JobTranscript`, a job's history as a Markdown file. `CodingJob` gains `model` and `question`; `DesktopJob` gains `model`.
- `usageLine` leaves out a zero cost, which subscription providers report and which says nothing.
- Add `GroupDraft`, `GroupChatRow`, and `ComposerTarget`, moved from the macOS app so iOS shares them, plus `GroupChat.deliveryKey`, `GroupMemberActivity.Status.label(for:)`, and `ActivityEvent.groupTitle`. `GroupDraft` also limits names to 80 characters, and `GroupChatRow.failure` carries the bot's name so a deleted bot's failed turn still shows; rows skip messages with no text or attachments.
- Add `Message.sources` and `SourceCitations`, which takes a group reply's citations of pages it read out of the text as `SourceChip`s.
- `messageLabel` names the bot of an assistant message that has an origin.
- Add `BotDesktopSession`, moved from the macOS app so iOS shares it, and `BotDesktopPreview`, a watch-only preview that wakes on request. `BotDesktopSession.close()` is now `leave()`, which also hands back a take the server confirms after the owner left; `controlKnown`, `controlLabel`, and `connecting` are new, and `action` is `.waiting` until the server first reports control.
- Add `APIClient.desktopRunning`, and `passive` on `desktopViewer` for a link that neither boots the bot's machine nor keeps it awake.
- Add `AgentDraft.tools(keeping:)` and `AgentDraft.desktopModelChoice`, moved from the macOS app.
- Replace the seeded avatars with Open Bot Avatar, a new dependency pinned by revision. `Agent.avatar` and `AgentDraft.avatar` are now a `BotAvatarDefinition`, read from and sent to the server; an invalid definition from the server falls back to the bot's starter shape. `BotAvatarView` takes a `BotAvatarDefinition` or an `Agent`, `BotAvatarEditor` is the shared editor, and `BotAvatarDefinition` gains `default(for:)`, `importing(json:)`, `recolored(color:eyeColor:)`, and `generationPrompt(_:)`.
- Remove `agentAvatarSeed`, the `bot:` and `critters:` seed prefixes, `AgentDraft.avatarChoices`, `shuffleAvatars()`, `BotLook`, `BotShape`, `BotFinish`, and `\.botFinish`.
- Add `APIClient.signIn(baseURL:email:password:session:)`, which returns the account session token.
- Update to bot contract 6.0.0 from a local export, since the bot repository no longer publishes contract releases. `activityFeed()` omits change activities. `setProviderKey` sends the secret body `{"value"}`.
- `AgentDraft` turns on `toolsDelegate`, `toolsSchedule`, and `toolsCodemode` by default.
- Add provider sign-in from bot contract 1.7.0. `ProviderStatus` gains `authMethods`, `credentialType`, and `activeLoginId`. `ProviderLogin` carries a server sign-in's status, its link, device-code, info, and progress events, and the prompt it waits on; `APIClient` starts, reads, answers, and cancels it. Pin bot contract `contract-v1.7.0`. `ProviderStatus` now lives in `ProviderLogin.swift`.
- Move into the `crumble-project/apple` repository, where the macOS and iOS apps depend on this package by path instead of a pinned revision.
- Add `ActivityEvent.jobName`: a reply to a coding or desktop job's report (origin `coding` or `desktop`) names its job, so notifications can say which job and open the bot desktop.
- Add desktop jobs from bot contract 1.6.0. `ServerCapabilities.desktop` says whether bots can get a bot desktop. `Agent.desktopModel` (a `DesktopModel`) is the model for a bot's desktop jobs, and `updateAgent` clears it with `["desktopModel": .null]`; `AgentDraft` gains `toolsDesktop`, `desktopProvider`, and `desktopModel`. `DesktopJob`, `APIClient.desktopJobs`, and `desktopJobHistory` mirror coding jobs, and `messageLabel` names desktop job reports.
- Add `JobUsage`, the tokens and cost a job's own model requests spent, summed over its models, on `DesktopJob.usage` and `CodingJob.usage`.
- Add taking control of a bot desktop: `DesktopControl`, `APIClient.desktopControl`, `setDesktopControl`, and the `desktopEvents` stream of control changes, validated as `EventDesktopControl`.
- Add `APIClient.desktopViewer`, a single-use `DesktopViewerLink` to the bot desktop's viewer page, resolved under the API's base URL, for a web view; it needs no token.
- Add `JSONValue.numberValue`.
- Pin the published contract-v1.6.0 release. `scripts/contract.py` now also fetches `desktop-control.schema.json` and generates it as `EventDesktopControl`.
- Pin the published bot contract `contract-v1.3.0`. The contract now carries `group-chat-snapshot.schema.json`, which the update script requires and generates as `EventGroupChatSnapshot`.
- Add group chats: `GroupChat`, `GroupActivity`, `GroupMemberActivity`, and `GroupChatSnapshot`, with `APIClient` operations to list, create, update, and delete groups, read snapshots and history, send messages with replies and attachments, stop a group, fetch attachments, and stream group snapshots. `SSEParser(snapshots: .group)` validates group snapshot events.
- Add `Route.group` for a selected group chat.
- Add `Reaction.byReplyTarget`, which keys group chat reactions by the message they answer and names who reacted.
- Add `groupId` and `groupName` to `ActivityEvent` for bot answers in group chats, and `MemorySource` to `Memory`.
- Replace the local glossary with a link to the canonical glossary in the spec repository.
- Time out SSE requests after 45 seconds without data instead of 24 hours. Servers send heartbeats every 15 seconds, so a connection that died silently, such as across sleep or a network change, now fails and the caller can reconnect.
- Pin bot contract `1.0.0` as a checksum-verified local export from source commit `40d7b6a`; adopt the published release before merging the integration.
- Generate and commit public Swift HTTP operations and event payload models with Apple Swift OpenAPI Generator `1.14.2` and Runtime `1.13.2`, without build plugins. Pin the CLI's complete dependency resolution and fail rather than silently updating its parser dependencies.
- Route every `APIClient` endpoint through typed generated operations, including attachment bytes and SSE. Preserve the injected URLSession, bearer authentication, request timeouts, cancellation, bounded errors, explicit nullable requests, and domain initializers.
- Share activity and push facades across Apple apps. Decode known SSE payloads through generated schemas while ignoring heartbeat and unknown event frames. Contract-required fields are now enforced at the wire boundary.
- Add deterministic regeneration checks, checksum-verified local or release updates, public CI, and a weekly contract updater that validates changes before opening a PR with `GITHUB_TOKEN`.

- Remove `folder` from `Agent` and `AgentDraft`. The server no longer has the field.
- Add `Reaction`, which reads the emoji from a bot's `react` tool result and groups reactions by the message they answer.
- Decode `toolName`, `isError`, and `toolDetails` on transcript messages, and add `DisplayComponent` for the visuals a bot shows with its `show` tool. Charts decode as `ChartLayout` drawing primitives with theme tokens; `ChartPalette` holds the light and dark series colors.
- Share `BotChatDelivery` and its behavior tests between the Apple clients. Keep transport tasks, connection guards, composer behavior, and native image conversion in each app.

- Send the device timezone with each chat message so bots know the owner's local time.
- Add `BotFinish` body finishes for bot avatars: glossy, matte, dither, halftone, grain, and outline, set with the `botFinish` environment value.
- Add the `BotAvatar` library with the shared bot avatar drawing, motion, and Core Animation live view for iOS and macOS.
- Extract common models, HTTP transport, event parsing, drafts, attachments, and pure helpers from the iOS and macOS clients.
- Connect both clients and their unit tests to `git@github.com:crumble-project/apfelkern.git`, tracking `main`.
- Preserve app-specific activity models, skill drafts, and invalid UTF-8 handling.
- Align iOS Debug builds with package dependencies by building only the selected simulator architecture.
