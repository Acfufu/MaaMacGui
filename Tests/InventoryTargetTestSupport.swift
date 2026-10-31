import Foundation

// 单文件编译桩:params(at:stageActivity:) 的活动上下文;真实实现见
// MeoAsstMac/Model/StageActivity.swift(activity-medicine 套件覆盖)。
struct MAAStageActivity {}
struct StageActivityContext {
    enum MedicineWindow: Equatable { case inactive, unavailable, extended(Int) }
    init(channel: String, activities: MAAStageActivity?) {}
    func medicineWindow(at date: Date, enabled: Bool) -> MedicineWindow { .inactive }
}
protocol MAATaskConfiguration: Codable, Hashable, Sendable {}
extension MAATaskConfiguration {
    init() { self = try! JSONDecoder().decode(Self.self, from: Data("{}".utf8)) }
}
enum MAATaskType { case Fight; var description: String { "Fight" } }
enum MAATask { case fight(FightConfiguration) }
