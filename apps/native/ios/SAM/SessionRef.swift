/// A conversation identified independently of the loaded project list.
struct SessionRef: Hashable {
    let projectId: String
    let sessionId: String
}
