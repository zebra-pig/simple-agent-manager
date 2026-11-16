// Runs the production ProjectSettings inside a real UIKit sheet. Only its core
// boundary is scripted so initial completion and refresh can be held for checks.
import SwiftUI
import UIKit

struct App {}
struct Project { var name = "Fixture"; var description: String?; var defaultBranch = "main"; var repoProvider = "github"; var repository = "example/project" }
struct ProjectDraft {
    let name, description, provider, installationId: String
    let repositoryId: UInt64?
    let repository, defaultBranch: String
}
struct Installation { var id: String; var accountName: String }
struct Repository { var id: UInt64; var fullName: String; var defaultBranch: String }
struct FixtureError { var message: String }
struct ManagementState {
    var project: Project?
    var installations: [Installation] = []
    var repositories: [Repository] = []
    var artifactsEnabled = true
    var initialized = false
    var loading = false
    var saving = false
    var error: FixtureError?
}
@MainActor @Observable final class ProjectManagementModel {
    static var current: ProjectManagementModel?
    var state = ManagementState()
    @ObservationIgnored lazy var core = FixtureCore(model: self)
    init(app: App) { Self.current = self }
}
@MainActor final class FixtureCore {
    unowned let model: ProjectManagementModel
    var pending: CheckedContinuation<Void, Never>?
    init(model: ProjectManagementModel) { self.model = model }
    func state() -> ManagementState { model.state }
    func load(projectId: String?) async {
        model.state.loading = true
        await withCheckedContinuation { pending = $0 }
        model.state.initialized = true
        model.state.loading = false
    }
    func loadRepositories(provider: String, installationId: String, search: String) async {
        model.state.loading = true
        await withCheckedContinuation { pending = $0 }
        model.state.loading = false
    }
    func finish() { pending?.resume(); pending = nil }
    func save(draft: ProjectDraft) async -> Project? { nil }
    func delete(confirmation: String) async -> Bool { false }
}

@main struct ProjectLoadingRegression: SwiftUI.App {
    var body: some Scene { WindowGroup { SheetHost().preferredColorScheme(.dark) } }
}
struct SheetHost: View {
    @State private var presented = true
    var body: some View {
        Text("Project list")
            .sheet(isPresented: $presented) { ProjectSettings(app: App()) { _ in } }
            .task { await verify() }
    }

    @MainActor private func settle() async { try? await Task.sleep(for: .milliseconds(700)) }
    @MainActor private func nameField() -> UITextField? {
        func find(_ view: UIView) -> UITextField? {
            if let field = view as? UITextField, field.placeholder == "Project name" { return field }
            return view.subviews.lazy.compactMap(find).first
        }
        return UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).lazy.compactMap(find).first
    }
    @MainActor private func frame() -> CGRect {
        guard let field = nameField(), let window = field.window else { fatalError("Production project name field missing") }
        return field.convert(field.bounds, to: window)
    }
    @MainActor private func capture(_ phase: String) {
        let window = nameField()!.window!
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        try! image.pngData()!.write(to: directory.appendingPathComponent(phase + ".png"))
    }
    private var directory: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    @MainActor private func verify() async {
        for _ in 0..<40 {
            if ProjectManagementModel.current?.state.loading == true, nameField() != nil { break }
            try? await Task.sleep(for: .milliseconds(200))
        }
        await settle()
        let model = ProjectManagementModel.current!
        precondition(model.state.loading, "Initial request was not held")
        let initial = frame()
        capture("initial-sheet")
        model.core.finish()
        await settle()
        precondition(model.state.initialized && !model.state.loading)
        let loaded = frame()
        capture("loaded-sheet")
        let refresh = Task { await model.core.loadRepositories(provider: "github", installationId: "fixture", search: "") }
        await settle()
        precondition(model.state.loading)
        let refreshing = frame()
        capture("refreshing-sheet")
        model.core.finish()
        await refresh.value
        await settle()
        let completed = frame()
        capture("refreshed-sheet")
        let shift = max(abs(initial.minY - loaded.minY), abs(refreshing.minY - loaded.minY), abs(completed.minY - loaded.minY))
        let result = "\(shift <= 1 ? "PASS" : "FAIL"): production New project sheet y positions \([initial.minY, loaded.minY, refreshing.minY, completed.minY]); maximum shift \(shift)pt"
        try! result.write(to: directory.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
        print(result)
    }
}
