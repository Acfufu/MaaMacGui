import Foundation

var checks = 0
func check(_ value: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    precondition(value(), message)
}

let rows: [(id: String, name: String, count: Int)] = [
    ("30011", "技巧概要·卷1", 12), ("30012", "技巧概要,卷2", 3), ("30013", "引\"留\"之间", 1),
]

// Depot Markdown：WPF BuildMarkdownExportLines 逐字同构（含表头与空行）。
let md = DataExport.depotMarkdownLines(rows: rows)
check(md[0] == "# Arknights Depot Export" && md[1] == "", "markdown title and blank line")
check(md[2] == "| ID | Name | Count |" && md[3] == "| --- | --- | --- |", "markdown table header")
check(md[4] == "| 30011 | 技巧概要·卷1 | 12 |", "markdown row passes names through verbatim")
check(md.count == 3 + 4, "one row per item")

// Depot CSV：RFC 4180 转义（逗号/引号/换行）。
let csv = DataExport.depotCsvLines(rows: rows)
check(csv[0] == "ID,Name,Count", "csv header literal")
check(csv[1] == "30011,技巧概要·卷1,12", "clean field unquoted")
check(csv[2] == "30012,\"技巧概要,卷2\",3", "comma field quoted")
check(csv[3] == "30013,\"引\"\"留\"\"之间\",1", "quote doubled inside quotes")
check(DataExport.csvField("a\nb") == "\"a\nb\"", "newline field quoted")
check(DataExport.csvField("plain") == "plain", "plain field untouched")

// OperBox：基础 7 列，own 的 是/否 映射，表头由调用方传入。
let headers = DataExport.OperBoxHeaders(
    name: "名称", id: "ID", rarity: "星级", elite: "精英化", level: "等级",
    own: "已持有", potential: "潜能", yes: "是", no: "否")
let opers: [DataExport.OperBoxRow] = [
    .init(name: "阿\"米\"娅,测试", id: "char_002_amiya", rarity: 5, elite: 2, level: 60, own: true, potential: 6),
    .init(name: "夜刀", id: "char_999_tenture", rarity: 2, elite: 0, level: 1, own: false, potential: 1),
]
let opMd = DataExport.operBoxMarkdownLines(rows: opers, headers: headers)
check(opMd[0] == "| 名称 | ID | 星级 | 精英化 | 等级 | 已持有 | 潜能 |", "operbox markdown header localized by caller")
check(opMd[1] == "| :-- | :-- | :-- | :-- | :-- | :-- | :-- |", "operbox markdown separator")
check(opMd[2] == "| 阿\"米\"娅,测试 | char_002_amiya | 5 | 2 | 60 | 是 | 6 |", "markdown row keeps raw name")
let opCsv = DataExport.operBoxCsvLines(rows: opers, headers: headers)
check(opCsv[0] == "名称,ID,星级,精英化,等级,已持有,潜能", "operbox csv header")
check(opCsv[1] == "\"阿\"\"米\"\"娅,测试\",char_002_amiya,5,2,60,是,6", "operbox csv name quoted and escaped")
check(opCsv[2] == "夜刀,char_999_tenture,2,0,1,否,1", "operbox csv no-column for unowned")

// joinedLines：空集 nil（不产生空文件），其余按 \n 连接。
check(DataExport.joinedLines([]) == nil, "empty export yields nil")
check(DataExport.joinedLines(["a", "b"]) == "a\nb", "lines joined with newline")

// 落盘：干员导出 UTF-8 BOM，仓库导出无 BOM；内容逐字节往返。
let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: dir) }
let bomURL = dir.appendingPathComponent("operbox.csv")
try DataExport.write("名称,ID", to: bomURL, withBOM: true)
var bomBytes = try Data(contentsOf: bomURL)
check(bomBytes.prefix(3) == Data([0xEF, 0xBB, 0xBF]), "operbox export carries UTF-8 BOM")
bomBytes.removeFirst(3)
check(String(decoding: bomBytes, as: UTF8.self) == "名称,ID", "BOM-stripped content round-trips")
let plainURL = dir.appendingPathComponent("depot.csv")
try DataExport.write("ID,Name,Count", to: plainURL, withBOM: false)
let plainBytes = try Data(contentsOf: plainURL)
check(plainBytes.prefix(1) != Data([0xEF]), "depot export stays BOM-free UTF-8")

print("PASS \(checks) depot/operbox export builder assertions (P16 T07/T09 base columns)")
