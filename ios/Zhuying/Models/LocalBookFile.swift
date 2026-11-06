import Foundation
struct LocalBookFile: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let bytes: Int
    let chapters: Int
}
