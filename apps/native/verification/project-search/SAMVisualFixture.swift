// Offline simulator harness: production ProjectView, Rust core and Swift bindings.
// UIKit is used only to drive the system search control and capture evidence.
import SwiftUI
import UIKit

final class SearchFixtureStore: CredentialStore, @unchecked Sendable {
    let credentials: Credentials
    init() {
        let base = CommandLine.arguments.first(where: { $0.hasPrefix("--base=") })!.dropFirst(7)
        credentials = Credentials(serverUrl: String(base), sessionCookie: "fixture=local-only")
    }
    func load() -> Credentials? { credentials }
    func save(credentials: Credentials) {}
    func clear() {}
}

@main struct SearchFixture: SwiftUI.App {
    private let app = App(store: SearchFixtureStore(), baseDomain: nil)
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                ProjectView(app: app,
                            project: Project(id: "p1", name: "Project One", repository: "example/project-one", activeSessionCount: 1),
                            changed: { _ in }, open: { _ in })
            }
            .preferredColorScheme(.light)
            .task { await verify() }
        }
    }

    @MainActor private func searchController(_ controller: UIViewController) -> UISearchController? {
        if let search = controller.navigationItem.searchController { return search }
        return controller.children.lazy.compactMap { searchController($0) }.first
    }

    @MainActor private func verify() async {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        for _ in 0..<60 {
            let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
            if let window = windows.first(where: { $0.isKeyWindow }),
               let root = window.rootViewController, let search = searchController(root) {
                try? await Task.sleep(for: .seconds(2))
                for (name, query) in [("all", ""), ("title", "  CAFÉ  "), ("id", "old-session"), ("no-results", "nothing matches"), ("cleared", "")] {
                    search.searchBar.text = query
                    search.searchBar.delegate?.searchBar?(search.searchBar, textDidChange: query)
                    search.searchResultsUpdater?.updateSearchResults(for: search)
                    try? await Task.sleep(for: .seconds(1))
                    let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                        window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                    }
                    try! image.pngData()!.write(to: directory.appendingPathComponent(name + ".png"))
                }
                try! "CAPTURED: production search field driven through title, ID, no-match and clear states; inspect images."
                    .write(to: directory.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        try! "FAIL: system search controller unavailable".write(to: directory.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
    }
}
