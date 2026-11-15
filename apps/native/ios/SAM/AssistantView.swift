import SwiftUI
import Security

@MainActor @Observable final class AssistantModel {
    let core: AssistantViewModel
    var state: AssistantState
    init(app: App) {
        core = AssistantViewModel(app: app, store: AssistantPersistence())
        state = core.state()
        core.setObserver(observer: Relay { [weak self] in self?.state = $0 })
    }
    deinit { core.clearObserver() }
}
extension Relay: AssistantObserver where State == AssistantState {
    func onStateChanged(state: AssistantState) { send(state) }
}
/// Durable, account-scoped retry receipts. Keep private prompts in Keychain.
final class AssistantPersistence: AssistantStore, @unchecked Sendable {
    func load(scope: String) -> AssistantPending? {
        var query = key(scope)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let request = json["requestKey"], let message = json["message"] else { return nil }
        return AssistantPending(requestKey: request, message: message)
    }
    func save(scope: String, pending: AssistantPending) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: ["requestKey": pending.requestKey, "message": pending.message]) else { return false }
        let query = key(scope)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }
    func clear(scope: String) { SecItemDelete(key(scope) as CFDictionary) }
    private func key(_ scope: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "org.simpleagentmanager.assistant", kSecAttrAccount as String: scope, kSecUseDataProtectionKeychain as String: true]
    }
}

struct AssistantView: View {
    let app: App
    @State private var model: AssistantModel
    @State private var draft = ""
    @State private var followsLatest = true
    @State private var scrollControl = ChatScrollControl()
    @State private var voice = AssistantVoice()
    @State private var earlierOpen = false
    @State private var linkedChat: SessionRef?
    @Environment(\.scenePhase) private var phase
    @Environment(\.openURL) private var openURL
    init(app: App) { self.app = app; _model = State(initialValue: AssistantModel(app: app)) }
    private var active: Bool { model.state.turns.contains { ["running", "accepted"].contains($0.state) } }
    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        Text("Private to you · Project work runs in visible project chats").font(.caption).foregroundStyle(.secondary)
                        if !model.state.work.isEmpty {
                            DisclosureGroup("Project work (\(model.state.work.count))") {
                                ForEach(model.state.work, id: \.actionId) { work in workCard(work) }
                            }.padding().glass(in: RoundedRectangle(cornerRadius: 20))
                        }
                        if model.state.legacyHistoryAvailable {
                            DisclosureGroup("Earlier SAM history", isExpanded: $earlierOpen) {
                                ForEach(model.state.earlier, id: \.id) { message in
                                    VStack(alignment: .leading) {
                                        Text(message.role == "user" ? "You" : "SAM").font(.caption)
                                        markdown(message.content)
                                    }.padding(.vertical, 8)
                                }
                                if !model.state.earlierLoaded || model.state.earlierCursor != nil {
                                    Button("Load earlier messages") { Task { await model.core.loadEarlier() } }.disabled(model.state.loading)
                                }
                            }.onChange(of: earlierOpen) { _, open in
                                if open && !model.state.earlierLoaded { Task { await model.core.loadEarlier() } }
                            }
                        }
                        if model.state.nextCursor != nil {
                            Button("Load older messages") { Task { await model.core.loadOlder() } }.disabled(model.state.loading)
                        }
                        if model.state.loaded && model.state.turns.isEmpty {
                            Text("Your private SAM assistant").font(.title2.bold())
                            ForEach(["What needs my attention?", "What is running across my projects?", "Show my recent ideas"], id: \.self) { suggestion in
                                Button(suggestion) { draft = suggestion }.glassButton()
                            }
                        }
                        ForEach(model.state.turns, id: \.id) { turn in turnCard(turn) }
                        Color.clear.frame(height: 1).id("bottom")
                            .onAppear { followsLatest = true }
                            .onDisappear { followsLatest = false }
                    }.padding().frame(maxWidth: 760).frame(maxWidth: .infinity)
                    .background(ChatScrollProbe(control: scrollControl))
                }
                .initialLoading(model.state.loading && !model.state.loaded)
                .interactiveKeyboardDismiss()
                .refreshable { await model.core.refresh() }
                .defaultScrollAnchor(.bottom)
                .overlay(alignment: .bottom) {
                    if !followsLatest {
                        ChatJumpButton {
                            scrollControl.jump(using: proxy, to: "bottom")
                        }
                    }
                }
                .onChange(of: model.state.turns.count) { old, new in
                    if old == 0 || (followsLatest && new == old + 1) { withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
                }
                .safeAreaInset(edge: .bottom) { composer }
            }
            .navigationTitle("SAM").inlineTitle()
            .navigationDestination(item: $linkedChat) { ref in ChatView(app: app, ref: ref) }
            .toolbar {
                ToolbarItem { Button("Settings", systemImage: "gearshape") { open("/settings") } }
            }
        }
        .onDisappear { voice.cancel() }
        .task(id: phase) {
            guard phase == .active else { voice.cancel(); return }
            while !Task.isCancelled {
                await model.core.refresh()
                try? await Task.sleep(for: .seconds(active ? 2 : 10))
            }
        }
    }
    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = model.state.error {
                Text(error.message).foregroundStyle(.red).font(.footnote)
                Button { Task { await model.core.refresh() } } label: {
                    LoadingLabel(title: "Refresh", loading: model.state.loading)
                }.disabled(model.state.loading)
            }
            if let pending = model.state.pending { Text(pending.message).font(.footnote).lineLimit(4) }
            if let error = voice.error { Text(error).foregroundStyle(.red).font(.footnote) }
            assistantComposer
            if voice.hasRecording {
                HStack {
                    Text("Recording… Tap stop when you’re done.").font(.caption)
                    Button("Cancel") { voice.cancel() }
                }.padding(.horizontal, 16)
            }
            if active { Text("Stopping SAM won’t cancel project work it already started.").font(.caption).foregroundStyle(.secondary) }
        }.padding(.top, 8)
    }
    private var assistantComposer: some View {
        var composer = Composer(placeholder: "Ask SAM…", text: $draft, busy: model.state.busy, files: nil) {
            if active {
                Task { await model.core.stop() }
            } else {
                let message = model.state.pending?.message ?? draft
                Task {
                    let accepted = await model.core.send(message: message, requestKey: UUID().uuidString)
                    if accepted && draft == message { draft = "" }
                }
            }
        }
        composer.inputEnabled = model.state.pending == nil && !model.state.busy
        composer.sendEnabled = active || (!voice.hasRecording && model.state.loaded && model.state.enabled
            && (model.state.error == nil || model.state.pending != nil))
        // A pending receipt retries its original message, even with an empty editor.
        composer.allowsEmpty = active || model.state.pending != nil
        composer.sendLabel = active ? "Stop" : model.state.pending == nil ? "Send" : "Retry"
        composer.sendIcon = active ? "stop.fill" : "arrow.up"
        composer.leadingControl = AnyView(voiceControl)
        return composer
    }

    private var voiceControl: some View {
        HStack {
            Button {
                if voice.hasRecording {
                    if let data = voice.finish() {
                        Task {
                            if let text = await model.core.transcribe(audio: data), !text.isEmpty {
                                draft += (draft.isEmpty ? "" : " ") + text
                            }
                        }
                    }
                } else { Task { await voice.start() } }
            } label: { Image(systemName: voice.hasRecording ? "stop.circle" : "mic") }
                .glassButton()
                .tint(.primary)
                .buttonBorderShape(.circle)
                .accessibilityLabel(voice.hasRecording ? "Transcribe recording" : "Record voice message")
                .disabled(model.state.busy || model.state.pending != nil || active)
        }
    }
    private func turnCard(_ turn: AssistantTurn) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Spacer(minLength: 30); Text(turn.message).textSelection(.enabled).padding().glass(in: RoundedRectangle(cornerRadius: 20)) }
            Text("SAM · \(turn.state.replacingOccurrences(of: "_", with: " "))").font(.caption).foregroundStyle(.secondary)
            if let live = turn.live, ["running", "accepted"].contains(turn.state) {
                HStack { ProgressView().controlSize(.small); Text(live.phase.capitalized).font(.caption) }
                if let thinking = live.thinking { ThinkingView(text: thinking, font: .footnote) }
                ForEach(live.activity, id: \.id) { item in Text("\(assistantOperation(item.operation)) · \(item.state)").font(.caption) }
                if !live.text.isEmpty { markdown(live.text) }
            }
            if let response = turn.response { markdown(response) }
            if let error = turn.error { Text(error).foregroundStyle(.red) }
            ForEach(turn.actions, id: \.id) { action in actionCard(action) }
        }
    }
    private func actionCard(_ action: AssistantAction) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(assistantOperation(action.operation)).font(.headline)
            Text(action.available == false ? "No longer available" : action.state.replacingOccurrences(of: "_", with: " ")).font(.caption).foregroundStyle(.secondary)
            if action.available != false {
                if action.state == "approval_required" {
                    Text(action.operation == "sam_work_stop" ? "This cancels the running work and shuts down its workspace." : action.operation == "sam_agent_answer" ? "This sends your answer to the agent waiting in that chat." : "SAM needs your OK before doing this.")
                }
                if action.inputJson != "{}" || action.resultJson != nil {
                    if action.state == "approval_required" { Text(action.inputJson).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                    else { DisclosureGroup("Exact request") { Text(action.inputJson).font(.system(.caption, design: .monospaced)).textSelection(.enabled) } }
                    if let result = action.resultJson { DisclosureGroup("Recorded result") { Text(result).font(.system(.caption, design: .monospaced)).textSelection(.enabled) } }
                }
                if let link = assistantActionLink(action: action) { destination(link) }
                if action.state == "approval_required" {
                    HStack {
                        Button("Confirm", role: action.operation == "sam_work_stop" ? .destructive : nil) { Task { await model.core.confirm(actionId: action.id, approved: true) } }.glassButton()
                        Button("Decline") { Task { await model.core.confirm(actionId: action.id, approved: false) } }.glassButton()
                    }.disabled(model.state.busy)
                }
                if action.state == "uncertain" {
                    Text("SAM couldn’t confirm whether this finished. Check the project before asking again.").font(.footnote)
                    if action.operation == "sam_chat_start" { Button("Check outcome") { Task { await model.core.reconcile(actionId: action.id) } }.disabled(model.state.busy) }
                }
            }
        }.padding().glass(in: RoundedRectangle(cornerRadius: 20))
    }
    private func workCard(_ work: AssistantWork) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(work.taskTitle ?? String(localized: "Untitled task")).font(.headline)
            if let name = work.projectName { Text(name).font(.caption) }
            Text(work.status.replacingOccurrences(of: "_", with: " ")).font(.caption)
            if work.attention { Label("Needs attention", systemImage: "exclamationmark.circle") }
            if let error = work.error { Text(error).foregroundStyle(.red) }
            if let session = work.sessionId {
                NavigationLink("Open chat") { ChatView(app: app, ref: SessionRef(projectId: work.projectId, sessionId: session)) }
            } else { destination("/projects/\(work.projectId)/tasks/\(work.taskId)") }
            if let updates = work.updates, updates.unread > 0 {
                Text("\(updates.unread) new updates").font(.caption)
                Button("Mark seen") { Task { await model.core.markSeen(actionId: work.actionId) } }.disabled(model.state.busy)
            }
        }.padding(.vertical, 8)
    }
    @ViewBuilder private func destination(_ link: String) -> some View {
        let parts = link.split(separator: "/").map(String.init)
        if parts.count == 4, parts[0] == "projects", parts[2] == "chat" {
            NavigationLink("Open chat") { ChatView(app: app, ref: SessionRef(projectId: parts[1].removingPercentEncoding ?? parts[1], sessionId: parts[3].removingPercentEncoding ?? parts[3])) }
        } else { Button("Open on web") { open(link) } }
    }
    private func open(_ link: String) {
        let parts = link.split(separator: "/").map(String.init)
        if link.hasPrefix("/projects/"), parts.count == 4, parts[2] == "chat" {
            linkedChat = SessionRef(projectId: parts[1].removingPercentEncoding ?? parts[1], sessionId: parts[3].removingPercentEncoding ?? parts[3])
            return
        }
        if let url = notificationUrl(serverUrl: app.state().serverUrl, actionUrl: link).flatMap(URL.init(string:)) { openURL(url) }
    }
    private func markdown(_ text: String) -> some View {
        Text((try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)).textSelection(.enabled)
            .environment(\.openURL, OpenURLAction { url in open(url.absoluteString); return .handled })
    }
}
private func assistantOperation(_ name: String) -> String {
    name.replacingOccurrences(of: "sam_", with: "").replacingOccurrences(of: "_", with: " ").capitalized
}
