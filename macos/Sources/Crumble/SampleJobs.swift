#if DEBUG
    import apfelkern
    import SwiftUI

    /// Made-up jobs for looking at the job panel without running one: a coding job and a desktop job
    /// with replies, finished and failed steps, and one still running. Debug builds only.
    enum SampleJobs {
        static func history(_ kind: JobKind, agentID: String) -> JobHistory {
            let name = kind == .coding ? "fix-login-redirect" : "book-table"
            var history = JobHistory(agentID: agentID, kind: kind, name: name)
            let entries = kind == .coding ? coding : desktop
            history.items = entries.enumerated().map { $1.item(id: "sample-\($0)") }
            history.loaded = true
            return history
        }

        private enum Entry {
            case task(String)
            case reply(String)
            case step(Step)

            func item(id: String) -> JobHistoryItem {
                switch self {
                case .task(let text): .task(.init(id: id, kind: .task, text: text))
                case .reply(let text): .reply(.init(id: id, kind: .reply, text: text))
                case .step(let step): .step(step.item(id: id))
                }
            }
        }

        private struct Step {
            let tool: String
            let subject: String
            var output: String?
            var failed = false

            private var label: (String, JobStepItem.IconPayload) {
                switch tool {
                case "bash": ("Ran", .terminal)
                case "read": ("Read", .file)
                case "edit": ("Edited", .pencil)
                default: ("Used the bot desktop", .pointer)
                }
            }

            func item(id: String) -> JobStepItem {
                let result = output.map {
                    Components.Schemas.TranscriptMessage(
                        content: $0, entryId: id + "-entry", id: id + "-result", isError: failed,
                        replyReferences: [], role: "toolResult")
                }
                return JobStepItem(
                    icon: label.1, id: id, kind: .step, label: label.0, result: result, subject: subject, tool: tool)
            }
        }

        private static let coding: [Entry] = [
            .task("The login page redirects back to itself after a successful sign-in. Find out why and fix it."),
            .reply("I'll start by looking at how the redirect target is chosen after sign-in."),
            .step(Step(
                tool: "bash", subject: "rg -n \"redirect\" src/auth",
                output: """
                    src/auth/session.ts:42:  const next = url.searchParams.get("next") ?? "/login"
                    src/auth/routes.ts:88:  return redirect(next)
                    """)),
            .step(Step(
                tool: "read", subject: "src/auth/session.ts",
                output: """
                    export function nextPath(url: URL) {
                      const next = url.searchParams.get("next") ?? "/login"
                      return next
                    }
                    """)),
            .reply("""
                Found it: when there's no `next` parameter, the fallback is **`/login`** instead of the home \
                page, so a plain sign-in lands back on the login form.
                """),
            .step(Step(
                tool: "edit", subject: "src/auth/session.ts",
                output: """
                    -  const next = url.searchParams.get("next") ?? "/login"
                    +  const next = url.searchParams.get("next") ?? "/"
                    """)),
            .step(Step(
                tool: "bash", subject: "bun test src/auth",
                output: """
                    error: expected "/" but received "/login"
                      at session.test.ts:17

                    1 fail, 23 pass
                    """, failed: true)),
            .reply("One test still expects the old fallback. Updating it to match the intended behavior."),
            .step(Step(
                tool: "edit", subject: "src/auth/session.test.ts",
                output: """
                    -  expect(nextPath(url)).toBe("/login")
                    +  expect(nextPath(url)).toBe("/")
                    """)),
            .step(Step(tool: "bash", subject: "bun test src/auth"))
        ]

        private static let desktop: [Entry] = [
            .task("Book a table for two at Trattoria Lucia this Friday at 19:30."),
            .reply("Opening the restaurant's booking page on the bot desktop."),
            .step(Step(
                tool: "computer", subject: "open https://trattoria-lucia.example/book",
                output: "Opened the page. The booking form shows date, time, and party size.")),
            .step(Step(
                tool: "computer", subject: "fill date Friday, time 19:30, guests 2",
                output: "Filled the form. 19:30 is available.")),
            .reply("Friday at 19:30 is free. Confirming the booking under your name."),
            .step(Step(
                tool: "computer", subject: "click Confirm booking", output: "Booking confirmed. Reference: TL-4821.")),
            .reply("Done. Your table for two is booked for **Friday at 19:30**, reference `TL-4821`.")
        ]
    }

    extension AppModel {
        func openSampleJob(_ kind: JobKind) {
            openCall = nil
            jobHistory = SampleJobs.history(kind, agentID: selectedAgentID)
        }
    }

    /// Opens the sample jobs from the menu bar in debug builds.
    struct SampleJobCommands: Commands {
        let model: AppModel

        var body: some Commands {
            CommandMenu("Debug") {
                Button("Open Sample Coding Job") { model.openSampleJob(.coding) }
                Button("Open Sample Desktop Job") { model.openSampleJob(.desktop) }
            }
        }
    }
#endif
