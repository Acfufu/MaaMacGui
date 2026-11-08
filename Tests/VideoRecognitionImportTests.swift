import Darwin
import Foundation

// Exercise the C13 video-recognition import layer: output validation + move
// (GUI 生成文件回读), invalid-product discard, and leftover cache cleanup on
// cancel/failure. Production VideoRecognitionImport.swift /
// CopilotFileOperations.swift / MAACopilot.swift are compiled verbatim; the
// external copilot directory is redirected to a temp root by the script.

@main
struct VideoRecognitionImportTests {
    static func main() {
        setvbuf(stdout, nil, _IONBF, 0)

        var failures = [String]()
        var checkIndex = 0
        func check(_ condition: Bool, _ label: String) {
            checkIndex += 1
            if condition {
                print("PASS[\(checkIndex)]: \(label)")
            } else {
                failures.append(label)
                print("FAIL[\(checkIndex)]: \(label)")
            }
        }

        let work = FileManager.default.temporaryDirectory
            .appending(path: "video-recognition-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let externalRoot = work.appending(path: "external-copilot")
        URL.externalCopilotDirectoryOverride = externalRoot
        defer { URL.externalCopilotDirectoryOverride = nil }

        let validCopilot = #"{"stage_name":"OF-1","opers":[{"name":"Amiya","skill":1}],"minimum_required":"v4.0","doc":{"title":"T"}}"#
        let sssCopilot = #"{"stage_name":"SSS_1","opers":[],"minimum_required":"v4.0","type":"SSS"}"#

        // MARK: - A. importOutput

        let validURL = work.appending(path: "MaaAI_valid_1.json")
        try! Data(validCopilot.utf8).write(to: validURL)
        let outcome = VideoRecognitionImport.importOutput(filename: validURL.path(percentEncoded: false))
        check(
            outcome == .imported(
                URL.externalCopilotDirectory.appending(path: "MaaAI_valid_1.json"), name: "MaaAI_valid_1"),
            "valid product imports into the external directory")
        check(
            !FileManager.default.fileExists(atPath: validURL.path(percentEncoded: false)),
            "source product no longer on cache path after move")
        check(
            MAACopilot(
                url: URL.externalCopilotDirectory.appending(path: "MaaAI_valid_1.json")) != nil,
            "imported file re-parses as a copilot (GUI 生成文件回读)")

        let sssURL = work.appending(path: "MaaAI_sss_2.json")
        try! Data(sssCopilot.utf8).write(to: sssURL)
        check(
            VideoRecognitionImport.importOutput(filename: sssURL.path(percentEncoded: false))
                != .discardedInvalid,
            "SSS-shaped product also imports")

        let invalidURL = work.appending(path: "MaaAI_broken_3.json")
        try! Data(#"{"stage_name":"OF-1""#.utf8).write(to: invalidURL)
        check(
            VideoRecognitionImport.importOutput(filename: invalidURL.path(percentEncoded: false))
                == .discardedInvalid,
            "unparseable product reports discardedInvalid")
        check(
            !FileManager.default.fileExists(atPath: invalidURL.path(percentEncoded: false)),
            "unparseable product is deleted instead of imported")

        let missing = VideoRecognitionImport.importOutput(
            filename: work.appending(path: "MaaAI_missing_4.json").path(percentEncoded: false))
        check(missing == .discardedInvalid, "missing product discards instead of crashing")

        // MARK: - B. leftover cleanup

        let userDirectory = work.appending(path: "user")
        let cache = VideoRecognitionImport.cacheDirectory(userDirectory: userDirectory)
        try! FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let leftover1 = cache.appending(path: "MaaAI_left_1.json")
        let leftover2 = cache.appending(path: "MaaAI_left_2.json")
        let keeper = cache.appending(path: "notes.txt")
        try! Data(validCopilot.utf8).write(to: leftover1)
        try! Data(validCopilot.utf8).write(to: leftover2)
        try! Data("keep".utf8).write(to: keeper)
        VideoRecognitionImport.discardLeftoverCacheFiles(userDirectory: userDirectory)
        check(
            !FileManager.default.fileExists(atPath: leftover1.path(percentEncoded: false))
                && !FileManager.default.fileExists(atPath: leftover2.path(percentEncoded: false)),
            "leftover json files are discarded")
        check(
            FileManager.default.fileExists(atPath: keeper.path(percentEncoded: false)),
            "non-json cache content is untouched")
        check(
            !FileManager.default.fileExists(
                atPath: URL.externalCopilotDirectory.appending(path: "MaaAI_left_1.json").path),
            "leftovers are not imported into the external directory")

        // Empty/missing cache directory is a no-op.
        VideoRecognitionImport.discardLeftoverCacheFiles(userDirectory: work.appending(path: "absent"))

        if failures.isEmpty {
            print("ALL \(checkIndex) CHECKS PASSED")
        } else {
            print("\(failures.count)/\(checkIndex) CHECKS FAILED")
            FileHandle.standardError.write(Data(failures.joined(separator: "\n").utf8))
            exit(1)
        }
    }
}
