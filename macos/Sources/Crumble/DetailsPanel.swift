import apfelkern
import BotAvatar
import SwiftUI

/// The inspector beside a chat: the bot's live portrait, its routines, and what it remembers.
struct DetailsPanel: View {
    @Environment(AppModel.self) private var model
    let agent: Agent
    @State private var tab = Tab.details

    enum Tab { case details, memory }

    var body: some View {
        VStack(spacing: 0) {
            header
            Form {
                Section {
                    Picker("View", selection: $tab) {
                        Text("Details").tag(Tab.details)
                        Text("Memory").tag(Tab.memory)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                switch tab {
                case .details:
                    routines
                    modelSection
                case .memory:
                    memories
                }
            }
            .formStyle(.grouped)
        }
        .task(id: agent.id) { model.loadAgentDetails(agent.id) }
    }

    private var header: some View {
        VStack(spacing: 2) {
            BotAvatarView(agent: agent, size: 84, state: model.botState(agent), live: true)
            Text(agent.name).font(.title3.weight(.semibold)).padding(.top, 4)
            Text(agent.description?.nilIfEmpty ?? (agent.enabled ? "Ready" : "Paused"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
            Button("Edit Profile…") { model.openEditor(agentID: agent.id) }
                .buttonStyle(.link)
                .font(.callout)
                .padding(.top, 4)
        }
        .padding(.horizontal, 20)
        .padding(.top, 24)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity)
    }

    private var routines: some View {
        let items = model.schedules.filter { $0.agentId == agent.id }
        return Section("Routines") {
            if items.isEmpty {
                Text("No routines yet").foregroundStyle(.secondary)
            }
            ForEach(items) { schedule in
                Toggle(
                    isOn: Binding(
                        get: { schedule.enabled },
                        set: { model.setScheduleEnabled(schedule.id, $0) })
                ) {
                    Text(schedule.name)
                    Text(cadence(schedule))
                }
                .toggleStyle(.switch)
                .disabled(schedule.id.hasPrefix("pending-"))
            }
        }
    }

    private var modelSection: some View {
        Section("Model") {
            LabeledContent("Model", value: agent.model?.nilIfEmpty ?? "Default")
            if let provider = agent.provider?.nilIfEmpty {
                LabeledContent("Provider", value: provider)
            }
        }
    }

    private var memories: some View {
        Section("Memories") {
            if let items = model.agentMemories[agent.id] {
                if items.isEmpty {
                    Text("Nothing remembered yet").foregroundStyle(.secondary)
                }
                ForEach(items) { memory in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(memory.content).lineLimit(4).textSelection(.enabled)
                        if let source = memorySourceLabel(memory.source) {
                            Text(source).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity)
            }
        }
    }
}

/// How often a routine runs, in words for the cron shapes people use; others show their expression.
func cadence(_ schedule: Schedule, now: Date = .now) -> String {
    guard let cron = schedule.cron?.nilIfEmpty else {
        guard let runAt = schedule.runAt, let date = taskRunDate(runAt) else { return "Once" }
        let when = date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        return date > now ? "Once, \(when)" : "Ran \(when)"
    }
    return cronPhrase(cron, timezone: schedule.timezone)
}

/// A cron expression in words for the shapes people use, or the expression itself.
private func cronPhrase(_ cron: String, timezone: String?) -> String {
    let fields = cron.split(separator: " ").map(String.init)
    guard fields.count == 5 else { return cron }
    let (minute, hour, day, month, weekday) = (fields[0], fields[1], fields[2], fields[3], fields[4])
    if minute.hasPrefix("*/"), [hour, day, month, weekday] == ["*", "*", "*", "*"] {
        return "Every \(minute.dropFirst(2)) minutes"
    }
    if hour == "*", [day, month, weekday] == ["*", "*", "*"], let minute = Int(minute) {
        return "Every hour at :" + String(format: "%02d", minute)
    }
    guard let hourValue = Int(hour), let minuteValue = Int(minute), day == "*", month == "*",
        let time = Calendar.current.date(from: DateComponents(hour: hourValue, minute: minuteValue))
    else { return cron }
    let names = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
    let days: String
    switch weekday {
    case "*": days = "Every day"
    case "1-5", "MON-FRI": days = "Weekdays"
    case "0,6", "6,0", "SAT,SUN": days = "Weekends"
    default:
        guard let index = Int(weekday), (0...7).contains(index) else { return cron }
        days = "Every " + names[index % 7]
    }
    let phrase = "\(days) at \(time.formatted(date: .omitted, time: .shortened))"
    // Cron times are in the routine's own zone; name it when that isn't this Mac's.
    if let zone = timezone?.nilIfEmpty, zone != TimeZone.current.identifier {
        return phrase + " (\(zone))"
    }
    return phrase
}
