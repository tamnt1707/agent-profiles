import SwiftUI
import AgentProfilesCore

/// A ping sent through the CLI of the profile at fixed times, so the 5 hour
/// window of the subscription starts when the user wants it to. It edits the
/// draft of the profile; the page that shows it saves.
struct HeartbeatSection: View {
    @Bindable var model: AppModel
    /// The result of the last run, read from the result file of the agent.
    @State private var last: HeartbeatResult?

    /// A ping sent through the CLI of the profile at fixed times, so the 5 hour
    /// window of the subscription starts when the user wants it to.
    var body: some View {
        Section(model.loc.t("heartbeat.section")) {
            Toggle(model.loc.t("heartbeat.enabled"), isOn: heartbeatEnabled())
            Text(model.loc.t("heartbeat.hint"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if model.draft?.heartbeat.enabled == true {
                let times = model.draft?.heartbeat.times ?? []
                ForEach(times.indices, id: \.self) { index in
                    HStack(spacing: 8) {
                        DatePicker(
                            model.loc.t("heartbeat.time"),
                            selection: heartbeatTime(at: index),
                            displayedComponents: .hourAndMinute
                        )
                        Text(model.loc.t("heartbeat.window", times[index].text, times[index].windowEnd.text))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Button {
                            model.draft?.heartbeat.times.remove(at: index)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help(model.loc.t("heartbeat.remove"))
                    }
                }
                HStack(spacing: 12) {
                    Button(model.loc.t("heartbeat.add")) { addHeartbeatTime() }
                        .disabled(times.count >= Heartbeat.maxTimes)
                    if model.currentProfile?.heartbeat.isActive == true,
                       model.currentProfile?.heartbeat == model.draft?.heartbeat {
                        Button(model.loc.t("heartbeat.runNow")) { model.runHeartbeatNow() }
                            .help(model.loc.t("heartbeat.runNow.help"))
                    }
                }

                LabeledContent(model.loc.t("heartbeat.days")) {
                    HStack(spacing: 4) {
                        ForEach(1...7, id: \.self) { day in
                            Toggle(model.loc.t("heartbeat.day.\(day)"), isOn: heartbeatDay(day))
                                .toggleStyle(.button)
                                .controlSize(.small)
                        }
                    }
                }
                Text(model.loc.t(model.draft?.heartbeat.days.isEmpty == false ? "heartbeat.days.some" : "heartbeat.days.all"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                lastRunView
            }
        }
        // The agent writes its result when a run ends, so the file is looked at
        // now and every few seconds while this section is on screen.
        .task(id: model.currentProfile?.slug) {
            while !Task.isCancelled {
                if let slug = model.currentProfile?.slug {
                    let result = model.heartbeatResult(of: slug)
                    if result != last { last = result }
                } else if last != nil {
                    last = nil
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    /// When the last ping ended and how it went, so it can be checked later.
    @ViewBuilder
    private var lastRunView: some View {
        if let last {
            let when = last.date.formatted(date: .abbreviated, time: .standard)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: last.isSuccess ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundColor(Color(nsColor: last.isSuccess ? .systemGreen : .systemRed))
                    Text(last.isSuccess
                         ? model.loc.t("heartbeat.last.ok", when)
                         : model.loc.t("heartbeat.last.failed", when, String(last.exitCode)))
                        .font(.callout)
                }
                if !last.output.isEmpty {
                    Text(last.output)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
            }
        } else if model.currentProfile?.heartbeat.isActive == true {
            Text(model.loc.t("heartbeat.last.none"))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func heartbeatEnabled() -> Binding<Bool> {
        Binding(
            get: { model.draft?.heartbeat.enabled ?? false },
            set: { enabled in
                guard SettingsChange.isDifferent(model.draft?.heartbeat.enabled, enabled) else { return }
                model.draft?.heartbeat.enabled = enabled
                // A schedule that is turned on starts with one time, not with nothing.
                if enabled, model.draft?.heartbeat.times.isEmpty == true { addHeartbeatTime() }
            }
        )
    }

    private func heartbeatDay(_ day: Int) -> Binding<Bool> {
        Binding(
            get: { model.draft?.heartbeat.days.contains(day) ?? false },
            set: { on in
                guard SettingsChange.isDifferent(model.draft?.heartbeat.days.contains(day), on) else { return }
                if on { model.draft?.heartbeat.days.insert(day) } else { model.draft?.heartbeat.days.remove(day) }
            }
        )
    }

    /// The time of the row as a date of today on the clock of the Mac: the
    /// picker needs a date, the schedule stores only the time of day.
    private func heartbeatTime(at index: Int) -> Binding<Date> {
        Binding(
            get: { heartbeatDate(at: index) },
            set: { date in
                guard SettingsChange.isDifferent(heartbeatDate(at: index), date) else { return }
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                guard let hour = parts.hour, let minute = parts.minute,
                      let time = ClockTime(hour: hour, minute: minute),
                      model.draft?.heartbeat.times.indices.contains(index) == true,
                      SettingsChange.isDifferent(model.draft?.heartbeat.times[index], time) else { return }
                model.draft?.heartbeat.times[index] = time
            }
        )
    }

    private func heartbeatDate(at index: Int) -> Date {
        guard let time = model.draft?.heartbeat.times[safe: index] else { return Date() }
        return Calendar.current.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: Date()) ?? Date()
    }

    /// 05:00 for the first time, then the end of the last window: the next
    /// window starts when the one before it is over.
    private func addHeartbeatTime() {
        let last = model.draft?.heartbeat.times.last
        let next = last?.windowEnd ?? ClockTime(hour: 5, minute: 0)
        if let next { model.draft?.heartbeat.times.append(next) }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
