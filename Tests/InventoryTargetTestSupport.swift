import Foundation

// 单文件编译桩:P06.1 起 FightConfiguration 引用真实目录/活动层
// （StageCatalog/StageActivityContext/FightStage），活动桩面失效——本套件
// 编译面已改为装载真实实现（见 run-inventory-target-tests.sh），此处仅保留
// 任务壳桩。
protocol MAATaskConfiguration: Codable, Hashable, Sendable {}
extension MAATaskConfiguration {
    init() { self = try! JSONDecoder().decode(Self.self, from: Data("{}".utf8)) }
}
enum MAATaskType { case Fight; var description: String { "Fight" } }
enum MAATask { case fight(FightConfiguration) }
