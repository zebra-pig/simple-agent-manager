extension Array where Element: Identifiable {
    /// The elements with the first of each id, in order.
    ///
    /// A diffable data source raises an exception and terminates the app when
    /// a snapshot repeats an item identifier, so the transcript drops repeats
    /// before it builds one.
    func uniquedByID() -> [Element] {
        var seen = Set<Element.ID>()
        return filter { seen.insert($0.id).inserted }
    }
}
