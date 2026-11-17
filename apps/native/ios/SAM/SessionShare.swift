import SwiftUI

/// "Share chat access": who can use this chat, and adding a teammate for a
/// limited time. Wording follows web's Share dialog.
struct ShareView: View {
    let ref: SessionRef
    let shareable: Bool
    let topic: String?
    @State private var model: SessionAccessModel
    @State private var search = ""
    @State private var removing: AccessGrant?

    init(app: App, ref: SessionRef, shareable: Bool, topic: String?) {
        self.ref = ref
        self.shareable = shareable
        self.topic = topic
        _model = State(initialValue: SessionAccessModel(app: app))
    }

    private var state: SessionAccessState { model.state }
    private var ownerWords: OwnerWords { OwnerWords(owner: state.owner) }
    private var candidates: [ShareCandidate] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return state.candidates }
        return state.candidates.filter { $0.label.lowercased().contains(query) || ($0.email?.lowercased().contains(query) ?? false) }
    }

    var body: some View {
        SessionToolSheet(title: "Share", loading: state.loading, errors: [state.error?.message]) {
            await model.core.load(projectId: ref.projectId, sessionId: ref.sessionId, shareable: shareable)
        } content: {
            List {
                Section {
                    if let outcome = state.outcome {
                        Label { Text(verbatim: outcomeText(outcome)) } icon: { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                    }
                } footer: {
                    Text(verbatim: state.canManage
                         ? String(localized: "People you add can message the agent and manage this chat, just like you, for as long as you choose. It runs on \(ownerWords.possessive) accounts.")
                         : String(localized: "The people below can message the agent and manage this chat, just like the owner, until their access ends. It runs on \(ownerWords.possessive) accounts."))
                }
                Section("People with access") {
                    if let owner = state.owner {
                        HStack {
                            PersonLabel(person: owner)
                            Spacer()
                            Pill(text: String(localized: "Owner"))
                        }
                    }
                    ForEach(state.grants, id: \.id) { grant in
                        GrantRow(grant: grant, offset: state.serverOffsetMs)
                            .swipeActions {
                                if grant.grantee.isViewer || state.canManage {
                                    Button(grant.grantee.isViewer ? "Leave" : "Revoke", role: .destructive) { removing = grant }
                                }
                                if state.canRenew && !grant.grantee.isViewer {
                                    NavigationLink("Renew") { confirm(userId: grant.grantee.id, name: personName(grant.grantee), renewing: true) }.tint(.blue)
                                }
                            }
                            .contextMenu {
                                if state.canRenew && !grant.grantee.isViewer {
                                    NavigationLink { confirm(userId: grant.grantee.id, name: personName(grant.grantee), renewing: true) } label: {
                                        Label("Renew", systemImage: "clock.arrow.circlepath")
                                    }
                                }
                                if grant.grantee.isViewer || state.canManage {
                                    Button(grant.grantee.isViewer ? "Leave" : "Revoke now", systemImage: "person.badge.minus", role: .destructive) { removing = grant }
                                }
                            }
                    }
                    if state.loaded && state.grants.isEmpty {
                        Text("Only the owner can use this chat right now.").foregroundStyle(.secondary)
                    }
                }
                if state.loaded && state.canManage {
                    Section("Add a teammate") {
                        if !state.canAdd {
                            Text("This chat has ended, so no one else can be added.").foregroundStyle(.secondary)
                        } else if let none = state.noCandidates {
                            Text(noCandidatesText(none)).foregroundStyle(.secondary)
                        } else {
                            if state.candidates.count > 6 {
                                TextField("Search teammates", text: $search)
                            }
                            ForEach(candidates, id: \.userId) { person in
                                NavigationLink { confirm(userId: person.userId, name: person.label, renewing: false) } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(verbatim: person.label)
                                        if let email = person.email, email != person.label {
                                            Text(verbatim: email).font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .initialLoading(state.loading && !state.loaded)
            .confirmationDialog(removing.map { removalTitle($0) } ?? "", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
                if let grant = removing {
                    Button(grant.grantee.isViewer ? "Leave" : "Revoke now", role: .destructive) {
                        removing = nil
                        Task { _ = await model.core.revoke(userId: grant.grantee.id) }
                    }
                }
            } message: {
                if let grant = removing { Text(verbatim: removalDetail(grant)) }
            }
        }
    }

    private func confirm(userId: String, name: String, renewing: Bool) -> some View {
        ShareConfirmView(model: model, userId: userId, name: name, renewing: renewing, words: ownerWords)
    }

    private func removalTitle(_ grant: AccessGrant) -> String {
        grant.grantee.isViewer
            ? String(localized: "Leave this chat? You won't be able to send messages here anymore.")
            : String(localized: "Revoke \(personName(grant.grantee))'s access now? They won't be able to send messages here anymore.")
    }

    private func removalDetail(_ grant: AccessGrant) -> String {
        let cascades = state.grants.contains { $0.id != grant.id && $0.grantedBy.id == grant.grantee.id }
        let prefix = !cascades ? "" : grant.grantee.isViewer
            ? String(localized: "This also removes anyone you added. ") : String(localized: "This also removes anyone they added. ")
        return prefix + String(localized: "Work the agent already started keeps running.")
    }
}

/// Owner wording: "your" for the owner, "Ada's" for anyone else.
struct OwnerWords {
    let owner: AccessPerson?
    var possessive: String {
        guard let owner, !owner.isViewer else { return String(localized: "your") }
        return String(localized: "\(personName(owner))'s")
    }
    var object: String {
        guard let owner, !owner.isViewer else { return String(localized: "you") }
        return personName(owner)
    }
    var firstPersonPossessive: String {
        guard let owner, !owner.isViewer else { return String(localized: "my") }
        return String(localized: "\(personName(owner))'s")
    }
}

private func personName(_ person: AccessPerson) -> String {
    person.name ?? String(localized: "Someone")
}

private struct PersonLabel: View {
    let person: AccessPerson
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.crop.circle.fill").font(.title2).foregroundStyle(.secondary)
            Text(verbatim: personName(person) + (person.isViewer ? " " + String(localized: "(you)") : ""))
        }
    }
}

private struct GrantRow: View {
    let grant: AccessGrant
    let offset: Int64
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            PersonLabel(person: grant.grantee)
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(verbatim: detail(now: context.date))
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.leading, 36)
            }
        }
    }

    private func detail(now: Date) -> String {
        let by = grant.grantedBy.isViewer ? String(localized: "you") : (grant.grantedBy.name ?? String(localized: "someone"))
        let ends = Date(millis: grant.expiresAt - offset)
        let minutes = Int(ends.timeIntervalSince(now) / 60)
        let left = minutes < 1 ? String(localized: "under a minute") : String(localized: "\(minutes) min")
        return String(localized: "added by \(by) · ends in \(left) (\(ends.formatted(date: .omitted, time: .shortened)))")
    }
}

/// Picking how long, and acknowledging that it runs on the owner's accounts.
private struct ShareConfirmView: View {
    let model: SessionAccessModel
    let userId: String
    let name: String
    let renewing: Bool
    let words: OwnerWords
    @State private var minutes: UInt32?
    @State private var understood = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                bullet(String(localized: "\(name) can message and answer the agent, send files, schedule messages, and stop or archive the chat — just like you."))
                bullet(String(localized: "They can also look through the repository's files and changes. The terminal, open ports and the workspace page stay yours."))
                bullet(String(localized: "Everything runs on \(words.possessive) accounts: AI subscription or API key, GitHub access and compute. Agents it starts are billed to \(words.object)."))
                bullet(String(localized: "The agent can read \(words.possessive) keys, so \(name) may be able to see them, along with files like .env. Only share with people you trust."))
                bullet(String(localized: "Access ends on its own after the time you choose, or when it's revoked, and messages \(name) scheduled are cancelled. Ending it doesn't undo what \(name) did or stop work the agent already started, and keys they copied keep working until they're replaced."))
            }
            Section {
                Picker("How long?", selection: $minutes) {
                    ForEach(shareDurations(), id: \.self) { value in
                        Text(value == 60 ? String(localized: "1 hour") : String(localized: "\(value) min")).tag(UInt32?.some(value))
                    }
                }
                .pickerStyle(.segmented)
            } header: { Text("How long?") } footer: {
                if let minutes { Text(verbatim: endsText(minutes)) }
            }
            Section {
                Toggle("I understand this runs on \(words.firstPersonPossessive) accounts", isOn: $understood)
            }
        }
        .navigationTitle(renewing ? String(localized: "Renew \(name)'s access?") : String(localized: "Share with \(name)?"))
        .inlineTitle()
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    guard let minutes else { return }
                    Task { if await model.core.grant(userId: userId, durationMinutes: minutes, acknowledged: understood) { dismiss() } }
                } label: { LoadingLabel(title: renewing ? "Renew" : "Share", loading: model.state.saving) }
                .disabled(minutes == nil || !understood || model.state.saving)
            }
        }
    }

    private func bullet(_ text: String) -> some View {
        Label { Text(verbatim: text).font(.callout) } icon: { Image(systemName: "circle.fill").font(.system(size: 5)).foregroundStyle(.secondary) }
    }

    private func endsText(_ minutes: UInt32) -> String {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let end = shareEndsAt(state: model.state, minutes: minutes, now: now)
        let time = Date(millis: end).formatted(date: .omitted, time: .shortened)
        return end < now + Int64(minutes) * 60_000
            ? String(localized: "Ends at \(time), when your own access ends.") : String(localized: "Ends at \(time).")
    }
}

private func noCandidatesText(_ reason: NoCandidates) -> LocalizedStringKey {
    switch reason {
    case .nobodyElse: "No one else is in this project yet."
    case .onlyViewers: "Everyone else in this project can only view it."
    case .everyoneHasAccess: "Everyone who can be added already has access."
    }
}

private func outcomeText(_ outcome: ShareOutcome) -> String {
    let clock = { (millis: Int64) in Date(millis: millis).formatted(date: .omitted, time: .shortened) }
    switch outcome {
    case let .granted(name, until): return String(localized: "\(name) can use this chat until \(clock(until)).")
    case let .renewed(name, until): return String(localized: "\(name)'s access now ends at \(clock(until)).")
    case let .alreadyShared(name, until): return String(localized: "\(name) already has access, until \(clock(until)).")
    case let .revoked(name, cascaded, cancelled):
        return ([String(localized: "Revoked \(name)'s access.")] + removalExtras(cascaded, cancelled, you: false)).joined(separator: " ")
    case let .left(cascaded, cancelled):
        return ([String(localized: "You left this chat.")] + removalExtras(cascaded, cancelled, you: true)).joined(separator: " ")
    }
}

private func removalExtras(_ cascaded: UInt32, _ cancelled: UInt32, you: Bool) -> [String] {
    var parts: [String] = []
    if cascaded > 0 {
        let people = cascaded == 1 ? String(localized: "1 person") : String(localized: "\(cascaded) people")
        parts.append(you ? String(localized: "Also removed \(people) you added.") : String(localized: "Also removed \(people) they added."))
    }
    if cancelled > 0 {
        let messages = cancelled == 1 ? String(localized: "1 queued message") : String(localized: "\(cancelled) queued messages")
        parts.append(String(localized: "Cancelled \(messages) that hadn't reached the agent yet."))
    }
    return parts
}
