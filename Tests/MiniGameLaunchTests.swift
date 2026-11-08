import Darwin
import Foundation

// Exercise the Core CustomTask params builders (T12 event_shop blacklist /
// T16 auto_raise_potential) against the Core 51dac87 CustomTask.cpp contract:
// GUI sends {task_names, params}, Core reads plugin keys one level under
// `params` (event_shop.blacklist string array; auto_raise_potential.
// use_normal_token bool).

@main
struct MiniGameLaunchTests {
    static func main() throws {
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
        func jsonValue(_ object: [String: Any]) throws -> [String: Any] {
            let data = try JSONSerialization.data(withJSONObject: object)
            return try JSONSerialization.jsonObject(with: data) as! [String: Any]
        }

        // MARK: - T16 auto_raise_potential

        let raiseOn = try jsonValue(MiniGameLaunch.autoRaisePotential(useNormalToken: true))
        check(
            (raiseOn["auto_raise_potential"] as? [String: Any])?["use_normal_token"] as? Bool == true,
            "use_normal_token true nests one level under auto_raise_potential")
        let raiseOff = try jsonValue(MiniGameLaunch.autoRaisePotential(useNormalToken: false))
        check(
            (raiseOff["auto_raise_potential"] as? [String: Any])?["use_normal_token"] as? Bool == false,
            "use_normal_token false still explicit (Core default false, GUI 侧可回读)")

        // MARK: - T12 event_shop blacklist

        check(MiniGameLaunch.eventShop(blacklist: []) == nil, "empty blacklist omits params entirely")
        check(MiniGameLaunch.eventShop(blacklist: ["  ", ""]) == nil, "whitespace-only entries yield empty list")

        let blacklist = try jsonValue(
            MiniGameLaunch.eventShop(blacklist: [" 龙门币 ", "家具零件", ""])!)
        let eventShop = blacklist["event_shop"] as? [String: Any]
        let names = eventShop?["blacklist"] as? [String]
        check(names == ["龙门币", "家具零件"], "blacklist trims entries and drops empties")

        // Full payload as the VM assembles it stays JSON-encodable with string
        // array values (Core rejects non-string items).
        let payload: [String: Any] = [
            "task_names": ["SS@Store@Begin"],
            "params": MiniGameLaunch.eventShop(blacklist: ["龙门币"])!,
        ]
        let payloadData = try JSONSerialization.data(withJSONObject: payload)
        let reparsed = try JSONSerialization.jsonObject(with: payloadData) as! [String: Any]
        let reparsedNames = ((reparsed["params"] as! [String: Any])["event_shop"] as! [String: Any])["blacklist"] as! [String]
        check(reparsedNames == ["龙门币"], "full launch payload round-trips with string array")

        // MARK: - P17-[a] T03 clear_store 缺省对齐（快照 82 清单②裁定：随 WPF）
        // WPF Reclamation.cs:53 `ClearStore { get; set; } = true`——缺键/新装
        // 行为两平台一致；显式 false 保持（存量档案不暗改）。
        do {
            let absent = try JSONDecoder().decode(ReclamationConfiguration.self, from: Data("{}".utf8))
            check(absent.clear_store == true, "P17-[a]: absent clear_store defaults true (WPF parity)")
            let explicitFalse = try JSONDecoder().decode(
                ReclamationConfiguration.self, from: Data(#"{"clear_store":false}"#.utf8))
            check(explicitFalse.clear_store == false, "explicit false survives decode")
            let roundTrip = try JSONDecoder().decode(
                ReclamationConfiguration.self, from: JSONEncoder().encode(explicitFalse))
            check(roundTrip.clear_store == false, "explicit false round trip stable")
            let encodedAbsent = try JSONEncoder().encode(absent)
            check(
                String(decoding: encodedAbsent, as: UTF8.self).contains("\"clear_store\""),
                "encode emits clear_store explicitly (no silent absent-key drift)")
        } catch {
            failures.append("P17-[a] clear_store decode block threw: \(error)")
        }

        // MARK: - P17-[d]（快照 82 清单②裁定：随 WPF 对齐）四类预设关键词
        do {
            // 五语表逐字（WPF ToolboxViewModel.cs:3639-3646）。
            let expected: [(MiniGameLaunch.EventShopKeywordLanguage, String, String, String, String)] = [
                (.zhHans, "数据增补仪", "数据增补条", "龙门币", "家具"),
                (.zhHant, "數據增補儀", "數據增補條", "龍門幣", "傢俱"),
                (.en, "Data Supplement Instrument", "Data Supplement Stick", "LMD", "Furniture Part"),
                (.jp, "データ補完マシン", "データ補完チップ", "龍門幣", "家具"),
                (.kr, "데이터 리더기", "데이터 메모리", "용문폐", "가구 부품"),
            ]
            for (lang, instrument, stick, lmd, furniture) in expected {
                let got = MiniGameLaunch.eventShopPresetKeywords(language: lang)
                check(got.instrument == instrument && got.stick == stick && got.lmd == lmd
                        && got.furniturePart == furniture,
                      "P17-[d] preset keywords verbatim for \(lang)")
            }
            // 渠道归桶：EN/JP/KR 直映、txwy=繁中、Official/Bilibili/未知=简中
            //（WPF default 分支同）。
            let buckets: [(String, MiniGameLaunch.EventShopKeywordLanguage)] = [
                ("Official", .zhHans), ("Bilibili", .zhHans), ("YoStarEN", .en),
                ("YoStarJP", .jp), ("YoStarKR", .kr), ("txwy", .zhHant),
                ("UnknownChannel", .zhHans),
            ]
            for (raw, lang) in buckets {
                check(MiniGameLaunch.eventShopKeywordLanguage(channelRawValue: raw) == lang,
                      "P17-[d] channel bucket \(raw)")
            }
            // 组合语义（WPF :3635-3656 同构）：Other 门控、trim+剔空+Distinct
            // 保序、预设按固定序追加、自定义∩预设重复不去重。
            let composed = MiniGameLaunch.eventShopBlacklist(
                custom: ["  龙门币 ", "", "技能书", "龙门币"], otherEnabled: true,
                instrument: true, stick: false, lmd: true, furniturePart: false,
                channelRawValue: "Official")
            check(composed == ["龙门币", "技能书", "数据增补仪", "龙门币"],
                  "P17-[d] composition: Other gate + trim/distinct/preserve order + presets appended; custom∩preset dup kept (WPF parity)")
            let otherOff = MiniGameLaunch.eventShopBlacklist(
                custom: ["技能书"], otherEnabled: false,
                instrument: false, stick: true, lmd: false, furniturePart: true,
                channelRawValue: "YoStarEN")
            check(otherOff == ["Data Supplement Stick", "Furniture Part"],
                  "P17-[d] Other off drops custom; EN channel maps client-language keywords")
            let allEmpty = MiniGameLaunch.eventShopBlacklist(
                custom: [], otherEnabled: false,
                instrument: false, stick: false, lmd: false, furniturePart: false,
                channelRawValue: "Official")
            check(allEmpty.isEmpty, "P17-[d] all-off composition stays empty (params omitted upstream)")
        } catch {
            failures.append("P17-[d] block threw: \(error)")
        }

        if failures.isEmpty {
            print("ALL \(checkIndex) CHECKS PASSED")
        } else {
            print("\(failures.count)/\(checkIndex) CHECKS FAILED")
            FileHandle.standardError.write(Data(failures.joined(separator: "\n").utf8))
            exit(1)
        }
    }
}
