import Foundation

/// Only the first, unfinished token is autocomplete. Arguments and ordinary
/// prose must keep their editing and Return behavior.
struct SlashCommandQuery {
    let filter: String

    init?(draft: String) {
        guard draft.hasPrefix("/"), !draft.contains(where: \.isWhitespace) else { return nil }
        filter = String(draft.dropFirst())
    }

    func matches(_ commands: [SlashCommand]) -> [SlashCommand] {
        commands.filter { $0.name.lowercased().hasPrefix(filter.lowercased()) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
