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
    case Fight, Infrast
    var description: String { "Fight" }
}
// P08.2 起抽取面携带基建周计划门控与时间轮换；直接编译真 InfrastConfiguration
// （单一事实源，见 run-medicine-log-tests.sh swiftc 列表）。
struct UserDataUpdateConfiguration {}
struct UserDataUpdateRun { mutating func reset() {} }
enum MAATask { case fight(FightConfiguration), infrast(InfrastConfiguration), userdataupdate(UserDataUpdateConfiguration), other }
