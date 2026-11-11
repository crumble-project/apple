import Foundation

/// When an automation runs: its event source, its cron shape in words, or its one time.
public func cadence(_ schedule: Schedule, sources: [EventSource] = [], now: Date = .now) -> String {
  schedule.description
}

/// An automation's timing beside its switch, where a paused one says so.
public func automationTiming(_ schedule: Schedule, sources: [EventSource] = []) -> String {
  schedule.timing
}
