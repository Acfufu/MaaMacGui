import Foundation

// Core linkage and unrelated task metadata are excluded; configuration,
// calendar, activity decoding and legacy migration compile from production.
protocol MAATaskConfiguration: Codable, Hashable, Sendable {
    associatedtype Params: Encodable
    var params: Params { get }
}
extension MAATaskConfiguration {
    init() { self = try! JSONDecoder().decode(Self.self, from: Data("{}".utf8)) }
}
enum MAATaskType {
    case Fight
    var description: String { "Fight" }
}
// P08.1 起 startTasks 抽取面携带基建周计划门控；桩满足编译（真实门控行为
// 由模型层套件与 P08 交付面覆盖）。
struct InfrastCfgStub {
    var weeklyDays: [Int]? = nil
    var subtitle: String = ""
    func isScheduled(on weekday: Int) -> Bool { weeklyDays?.contains(weekday) ?? true }
}
enum MAATask { case fight(FightConfiguration), infrast(InfrastCfgStub), other }
