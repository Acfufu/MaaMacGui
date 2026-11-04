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
enum MAATask: Codable, Equatable {
    case infrast(InfrastConfiguration)
    // An unrelated payload ensures preference recovery ignores other task types.
    case closedown(String)
}
// P08.2 起编译真 MAAInfrast（时间轮换面依赖 period 解析；单一事实源）。
