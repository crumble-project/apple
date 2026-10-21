# Crumble interaction principles

Optimistic UI is a core product principle. Apply local user intent immediately for chat sends and record creation, editing, and deletion. Reconcile provisional IDs and messages with the server without duplicates. Preserve drafts and offer retry or rollback when a request fails.

Keep optimistic state scoped to its server and bot. A late response must preserve newer edits and navigation. Prevent refreshes from replacing pending local changes. Cover delayed responses, failure recovery, and reconciliation in tests.

Actions whose outcome depends on another system, such as authentication or starting remote work, show an immediate pending state. Show success only when confirmed.
