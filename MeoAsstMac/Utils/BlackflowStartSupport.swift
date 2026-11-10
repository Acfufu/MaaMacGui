import CryptoKit
import Foundation
import MachO
import OSLog

/// A development-only protocol attestation, until a released Core capability contract is available.
/// Matches v6.22.0 (901e01c60, MAA tag 2026-11-09; P02.1 pin 前进批) and its resources,
/// never an inferred minimum version.
/// Core 侧备注：本机 RelWithDebInfo arm64 构建，MaaDeps v2.15.1 的 coreml_provider_factory.h
/// 失配已按 maacore-setup 同款处置剔除（WITH_COREML 分支编译排除）——CoreML EP 不参与本指纹面。
/// compatibleOTATaskFingerprint 仍钉 2026-10-29 OTA 覆盖层，v6.22.x OTA 内容变更后须重审。
enum BlackflowStartSupport {
    static let coreFingerprint = "99c062825da60ae5ad10fc1f04327b68df8cb93afc87f092901f1e9f6ccff8f3"
    static let resourceFingerprint = "3d3d6ed89744d1c1da911222cdcc342990d7a80e3ddf1043b46694063cb61639"
    private static let resourcePaths = ["tasks", "roguelike/BlackFlow", "template/Roguelike/BlackFlow"]

    private static let logger = Logger(subsystem: "com.hguandl.MeoAsstMac", category: "BlackflowStartSupport")

    /// A loaded image and the application bundle are immutable while the process
    /// runs, so their fingerprints are computed at most once per launch instead
    /// of on every resource reload. Both probes are only read from the main actor.
    nonisolated(unsafe) private static var loadedCoreMatch: Bool?
    nonisolated(unsafe) private static var bundledResourcesMatch: Bool?

    static func matchesLoadedCore() -> Bool {
        #if DEBUG
        if let loadedCoreMatch { return loadedCoreMatch }
        for index in 0..<_dyld_image_count() {
            guard let name = _dyld_get_image_name(index) else { continue }
            let url = URL(fileURLWithPath: String(cString: name))
            if url.lastPathComponent == "libMaaCore.dylib" {
                let started = ContinuousClock.now
                let matches = (try? executableFingerprint(at: url)) == coreFingerprint
                loadedCoreMatch = matches
                logFingerprintDuration("core", since: started)
                return matches
            }
        }
        #endif
        return false
    }

    /// Cached probe for the immutable application bundle. Overlay roots change
    /// across reloads and must keep using the uncached `matchesResources(at:)`.
    static func matchesBundledResources(at root: URL) -> Bool {
        if let bundledResourcesMatch { return bundledResourcesMatch }
        let started = ContinuousClock.now
        let matches = matchesResources(at: root)
        bundledResourcesMatch = matches
        logFingerprintDuration("bundled resources", since: started)
        return matches
    }

    private static func logFingerprintDuration(_ subject: String, since started: ContinuousClock.Instant) {
        #if DEBUG
        let elapsed = String(describing: ContinuousClock.now - started)
        logger.debug("BlackFlow start gate fingerprint (\(subject, privacy: .public)) took \(elapsed, privacy: .public)")
        #endif
    }

    /// Ad-hoc signing changes __LINKEDIT and LC_CODE_SIGNATURE. Hash the UUID and all
    /// allocated executable/data bytes, excluding load commands and signature metadata.
    static func executableFingerprint(at url: URL) throws -> String? {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        func word(_ offset: Int) -> UInt32? {
            guard offset >= 0, offset <= data.count - 4 else { return nil }
            return data.withUnsafeBytes {
                UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
            }
        }
        guard word(0) == MH_MAGIC_64, let commandCount = word(16), let commandSize = word(20),
            commandSize <= data.count - 32
        else { return nil }
        let start = 32 + Int(commandSize)
        var offset = 32
        var uuid: Data?
        var end: Int?
        for _ in 0..<commandCount {
            guard let command = word(offset), let size = word(offset + 4), size >= 8,
                offset <= start - Int(size)
            else { return nil }
            if command == LC_UUID, size >= 24 { uuid = data.subdata(in: offset + 8..<offset + 24) }
            if command == LC_SEGMENT_64, size >= 72,
                String(data: data.subdata(in: offset + 8..<offset + 18), encoding: .utf8) == "__LINKEDIT",
                let low = word(offset + 40), let high = word(offset + 44), high == 0
            {
                end = Int(low)
            }
            offset += Int(size)
        }
        guard let uuid, let end, start <= end, end <= data.count else { return nil }
        var hash = SHA256()
        hash.update(data: uuid)
        hash.update(data: data.subdata(in: start..<end))
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func matchesResources(at root: URL) -> Bool {
        guard !FileManager.default.fileExists(atPath: root.appendingPathComponent("resource/tasks.json").path) else {
            return false
        }
        return (try? fingerprintResources(at: root.appendingPathComponent("resource"))) == resourceFingerprint
    }

    static func fingerprintResources(at resource: URL) throws -> String? {
        let resource = resource.resolvingSymlinksInPath().standardizedFileURL
        var files: [URL] = []
        for path in resourcePaths {
            let directory = resource.appendingPathComponent(path)
            guard
                let enumerator = FileManager.default.enumerator(
                    at: directory, includingPropertiesForKeys: [.isRegularFileKey])
            else {
                return nil
            }
            for case let file as URL in enumerator {
                if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                    files.append(file.resolvingSymlinksInPath().standardizedFileURL)
                }
            }
        }
        guard !files.isEmpty else { return nil }
        var hash = SHA256()
        for file in files.sorted(by: { $0.path < $1.path }) {
            guard file.path.hasPrefix(resource.path + "/") else { return nil }
            let relativePath = String(file.path.dropFirst(resource.path.count + 1))
            hash.update(data: Data(relativePath.utf8))
            hash.update(data: Data([0]))
            hash.update(data: try Data(contentsOf: file))
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // The 2026-10-29 OTA adds BlackFlowTemporary workaround tasks and changes
    // AccountManager, while preserving all existing roguelike tasks. Future
    // OTA changes require an explicit review before this development gate opens.
    static let compatibleOTATaskFingerprint = "e0180578c98f7666aeeeb033d2ac2ec657589fee5258025af904859f1d8d7b9a"

    static func permitsOverlay(at root: URL) -> Bool {
        let root = root.resolvingSymlinksInPath().standardizedFileURL
        if matchesResources(at: root) { return true }
        let resource = root.appendingPathComponent("resource")
        guard
            ["tasks.json", "roguelike", "template"].allSatisfy({
                !FileManager.default.fileExists(atPath: resource.appendingPathComponent($0).path)
            })
        else { return false }
        let tasks = resource.appendingPathComponent("tasks")
        guard FileManager.default.fileExists(atPath: tasks.path) else { return true }
        guard
            let enumerator = FileManager.default.enumerator(at: tasks, includingPropertiesForKeys: [.isRegularFileKey])
        else {
            return false
        }
        var files: [URL] = []
        for case let file as URL in enumerator {
            guard let regular = try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile else {
                return false
            }
            if regular { files.append(file) }
        }
        guard files.count == 1,
            files[0].standardizedFileURL == tasks.appendingPathComponent("tasks.json").standardizedFileURL,
            let data = try? Data(contentsOf: files[0])
        else { return false }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == compatibleOTATaskFingerprint
    }
}
