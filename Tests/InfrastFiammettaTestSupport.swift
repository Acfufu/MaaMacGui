import Foundation

// Only task metadata and unrelated plan file loading are replaced.
protocol MAATaskConfiguration: Codable, Hashable, Sendable {
    associatedtype Params: Encodable
    var params: Params { get }
}
extension MAATaskConfiguration {
    init() { self = try! JSONDecoder().decode(Self.self, from: Data("{}".utf8)) }
}
enum MAATaskType {
    case Infrast
    var description: String { "Infrast" }
}
enum MAATask { case infrast(InfrastConfiguration) }
struct MAAInfrast {
    struct Plan { let name: String? }
    let title: String? = nil
    let plans: [Plan] = []
    init(path: String) throws { throw CocoaError(.fileReadNoSuchFile) }
}
