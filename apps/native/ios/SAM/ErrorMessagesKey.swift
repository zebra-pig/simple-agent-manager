import SwiftUI

struct ErrorMessagesKey: PreferenceKey {
    static let defaultValue: [String] = []

    static func reduce(value: inout [String], nextValue: () -> [String]) {
        for message in nextValue() where !value.contains(message) {
            value.append(message)
        }
    }
}
