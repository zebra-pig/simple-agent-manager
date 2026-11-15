import SwiftUI

/// Which agent profile the next task runs with: a compact glass button beside
/// the composer attachment button that opens a menu of the project's
/// profiles, with "Edit" and "New profile" for the editor.
struct ProfileMenu: View {
    let model: ProjectModel
    /// `nil`: a new profile.
    let edit: (AgentProfile?) -> Void

    private var selected: AgentProfile? {
        model.state.profiles.first { $0.id == model.state.selectedProfileId }
    }

    var body: some View {
        Menu {
            Picker("Profile", selection: Binding(
                get: { model.state.selectedProfileId ?? "" },
                set: { model.core.selectProfile(profileId: $0) }
            )) {
                ForEach(model.state.profiles, id: \.id) { profile in
                    Text(verbatim: profile.name).tag(profile.id)
                }
            }
            .pickerStyle(.inline)
            Divider()
            if let selected, selected.editable {
                Button("Edit “\(selected.name)”…", systemImage: "slider.horizontal.3") { edit(selected) }
            }
            Button("New profile…", systemImage: "plus") { edit(nil) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "person.crop.circle")
                (selected.map { Text(verbatim: $0.name) } ?? Text("Project defaults"))
                    .font(.subheadline.weight(.semibold))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .contentShape(Rectangle())
        }
        // A button with our own label on every platform (macOS would draw a pop-up button).
        .menuStyle(.button)
        .glassButton()
        .buttonBorderShape(.capsule)
        .tint(.primary)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel(Text("Agent profile"))
        .accessibilityValue(selected?.name ?? String(localized: "Project defaults"))
    }
}

/// Creates or edits one of the project's agent profiles. Fields left on
/// "Default" (or empty) use the project's settings.
struct ProfileEditor: View {
    let model: ProjectModel
    /// `nil`: a new profile.
    let profile: AgentProfile?
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ProfileDraft
    @State private var confirmDelete = false

    init(model: ProjectModel, profile: AgentProfile?) {
        self.model = model
        self.profile = profile
        _draft = State(initialValue: profileDraft(profile: profile))
    }

    private var agents: [AgentOption] {
        var agents = model.state.agents
        if !draft.agentType.isEmpty, !agents.contains(where: { $0.id == draft.agentType }) {
            agents.insert(AgentOption(id: draft.agentType, name: draft.agentType, configured: true), at: 0)
        }
        return agents
    }

    private var efforts: [String] { supportedEfforts(agentType: draft.agentType) }
    private var saving: Bool { model.state.savingProfile }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $draft.name)
                    TextField("Description", text: $draft.description, axis: .vertical)
                        .lineLimit(1...3)
                }
                Section("Agent") {
                    Picker("Agent", selection: $draft.agentType) {
                        ForEach(agents, id: \.id) { agent in
                            Text(verbatim: agent.name).tag(agent.id)
                        }
                    }
                    TextField("Model", text: $draft.model, prompt: Text("Agent default"))
                        .autocorrectionDisabled()
                        .urlKeyboard()
                    if !efforts.isEmpty {
                        Picker("Effort", selection: $draft.effort) {
                            Text("Default").tag("")
                            ForEach(efforts, id: \.self) { Text(effortLabel($0)).tag($0) }
                        }
                    }
                    Picker("Permissions", selection: $draft.permissionMode) {
                        Text("Default").tag("")
                        ForEach(permissionModes(), id: \.self) { Text(permissionModeLabel($0)).tag($0) }
                    }
                    Picker("Work type", selection: $draft.taskMode) {
                        Text("Default").tag("")
                        ForEach(taskModes(), id: \.self) { Text(taskModeLabel($0)).tag($0) }
                    }
                }
                Section {
                    TextField("Extra instructions", text: $draft.systemPromptAppend, axis: .vertical)
                        .lineLimit(3...10)
                } header: {
                    Text("Instructions")
                } footer: {
                    Text("Added to the agent's system prompt in every chat with this profile.")
                }
                machineSection
                Section {
                    NumberField("Max turns", text: $draft.maxTurns)
                    NumberField("Timeout (minutes)", text: $draft.timeoutMinutes)
                } header: {
                    Text("Limits")
                } footer: {
                    Text("When the agent stops on its own. Empty uses the project's settings.")
                }
                if let error = model.state.profileError {
                    Section { Text(error.message).foregroundStyle(.red) }
                }
                if let profile {
                    Section {
                        Button("Delete profile", role: .destructive) { confirmDelete = true }
                            .disabled(saving)
                    }
                    .confirmationDialog("Delete “\(profile.name)”?", isPresented: $confirmDelete, titleVisibility: .visible) {
                        Button("Delete", role: .destructive) {
                            Task { if await model.core.deleteProfile(profileId: profile.id) { dismiss() } }
                        }
                    } message: {
                        Text("Chats that already use it keep running.")
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(profile == nil ? Text("New profile") : Text("Edit profile"))
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button("Save") {
                            let draft = draft
                            Task { if await model.core.saveProfile(profileId: profile?.id, draft: draft) { dismiss() } }
                        }
                        .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .onChange(of: draft.runtime) {
                // An instant container always runs a lightweight workspace.
                if draft.runtime == "cf-container" { draft.workspaceProfile = "lightweight" }
            }
            .onChange(of: draft.agentType) {
                // Another agent may not have this effort level.
                if !draft.effort.isEmpty && !efforts.contains(draft.effort) { draft.effort = "" }
            }
            .task { await model.core.loadAgents() }
            .interactiveDismissDisabled(saving)
        }
        .macSheet()
    }
}

extension ProfileEditor {
    private var instant: Bool { draft.runtime == "cf-container" }

    /// Where the agent runs: the runtime, the minimum machine, the workspace.
    @ViewBuilder private var machineSection: some View {
        Section {
            Picker("Runtime", selection: $draft.runtime) {
                Text("Default").tag("")
                ForEach(profileRuntimes(), id: \.self) { Text(runtimeLabel($0)).tag($0) }
            }
            if !instant {
                NumberField("Min. vCPUs", text: $draft.minVcpu, decimal: true)
                NumberField("Min. memory (GB)", text: $draft.minMemoryGb, decimal: true)
                NumberField("Min. disk (GB)", text: $draft.minDiskGb, decimal: true)
                Picker("Dedicated node", selection: Binding(
                    get: { draft.exclusiveNode.map { $0 ? "yes" : "no" } ?? "" },
                    set: { draft.exclusiveNode = $0.isEmpty ? nil : $0 == "yes" }
                )) {
                    Text("Default").tag("")
                    Text("Yes").tag("yes")
                    Text("No").tag("no")
                }
                if !draft.legacyVmSize.isEmpty {
                    LabeledContent("Machine size") {
                        HStack {
                            Text(humanized(draft.legacyVmSize))
                            Button("Clear") { draft.legacyVmSize = "" }
                                .buttonStyle(.borderless)
                        }
                    }
                }
            }
            Picker("Workspace", selection: $draft.workspaceProfile) {
                Text("Default").tag("")
                ForEach(workspaceProfiles(), id: \.self) { Text(workspaceProfileLabel($0)).tag($0) }
            }
            .disabled(instant)
            if !instant && draft.workspaceProfile != "lightweight" {
                LabeledContent("Devcontainer") {
                    TextField("Devcontainer", text: $draft.devcontainerConfigName, prompt: Text("Auto-detect"))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .autocorrectionDisabled()
                        .urlKeyboard()
                }
            }
        } header: {
            Text("Machine")
        } footer: {
            if instant {
                Text("An instant container starts in seconds, in a lightweight workspace without machine settings.")
            } else {
                Text("The smallest machine this profile runs on. Empty fields use the project's settings.")
            }
        }
    }
}

/// A labelled number in a form row; empty shows "Default".
struct NumberField: View {
    let label: LocalizedStringKey
    @Binding var text: String
    var decimal = false

    init(_ label: LocalizedStringKey, text: Binding<String>, decimal: Bool = false) {
        self.label = label
        _text = text
        self.decimal = decimal
    }

    var body: some View {
        LabeledContent(label) {
            TextField(label, text: $text, prompt: Text("Default"))
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .numberKeyboard(decimal: decimal)
        }
    }
}

/// `AGENT_PROFILE_RUNTIMES` for people (the web's "Cloud VM" and "Instant container").
func runtimeLabel(_ runtime: String) -> String {
    switch runtime {
    case "vm": String(localized: "Cloud VM", comment: "Profile runtime")
    case "cf-container": String(localized: "Instant container", comment: "Profile runtime")
    default: humanized(runtime)
    }
}

func workspaceProfileLabel(_ profile: String) -> String {
    switch profile {
    case "full": String(localized: "Full", comment: "Workspace profile")
    case "lightweight": String(localized: "Lightweight", comment: "Workspace profile")
    default: humanized(profile)
    }
}

/// The editor opens for an existing profile or a new one.
struct ProfileEditing: Identifiable {
    let profile: AgentProfile?
    var id: String { profile?.id ?? "new" }
}

/// "claude-opus-5-5 · max": what the profile runs, under its name.
func profileSummary(_ profile: AgentProfile) -> String {
    var parts = [profile.model ?? profile.agentType]
    if let effort = profile.effort, effort != "auto" { parts.append(effortLabel(effort)) }
    return parts.joined(separator: " · ")
}

/// `AGENT_EFFORT_LEVELS` for people.
func effortLabel(_ effort: String) -> String {
    switch effort {
    case "low": String(localized: "Low", comment: "Agent effort level")
    case "medium": String(localized: "Medium", comment: "Agent effort level")
    case "high": String(localized: "High", comment: "Agent effort level")
    case "xhigh": String(localized: "Extra high", comment: "Agent effort level")
    case "max": String(localized: "Max", comment: "Agent effort level")
    default: humanized(effort)
    }
}

/// `AGENT_PERMISSION_MODE_LABELS` in packages/shared/src/constants/agent-settings.ts.
func permissionModeLabel(_ mode: String) -> String {
    switch mode {
    case "default": String(localized: "Ask every time", comment: "Agent permission mode")
    case "acceptEdits": String(localized: "Accept edits", comment: "Agent permission mode")
    case "plan": String(localized: "Plan only", comment: "Agent permission mode")
    case "dontAsk": String(localized: "Don't ask", comment: "Agent permission mode")
    case "bypassPermissions": String(localized: "Bypass permissions", comment: "Agent permission mode")
    default: humanized(mode)
    }
}

/// `TASK_MODES`: a task ends in a pull request, a conversation doesn't.
func taskModeLabel(_ mode: String) -> String {
    switch mode {
    case "task": String(localized: "Task (opens a pull request)", comment: "Profile work type")
    case "conversation": String(localized: "Conversation", comment: "Profile work type")
    default: humanized(mode)
    }
}
