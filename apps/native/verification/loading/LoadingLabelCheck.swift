import SwiftUI

@main struct LoadingLabelCheck {
    @MainActor static func main() {
        for title: LocalizedStringKey in ["Refresh", "Load repositories", "Save"] {
            let idle = ImageRenderer(content: LoadingLabel(title: title, loading: false).padding(8)).cgImage!
            let busy = ImageRenderer(content: LoadingLabel(title: title, loading: true).padding(8)).cgImage!
            precondition(idle.width == busy.width && idle.height == busy.height,
                         "Loading changed the action label's dimensions")
        }
        print("PASS: three Apple action labels keep identical dimensions while loading")
    }
}
