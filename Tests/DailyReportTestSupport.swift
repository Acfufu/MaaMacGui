import Foundation

// 作战日报轻量测试集的 MAAClientChannel 替身：真实枚举定义在
// StartupConfiguration.swift，其协议链会拖入 Core/Maa.swift（MaaCore 桥接面），
// 无法进 swiftc 轻编译集。此处镜像 6 个 case；真实枚举增删 case 时本文件须同步
// （run-daily-report-tests.sh 的既有自包含测试架构约定）。

enum MAAClientChannel: String {
    case Official
    case Bilibili
    case YoStarEN
    case YoStarJP
    case YoStarKR
    case txwy
}
