import Foundation
var checks=0
func check(_ value:@autoclosure () -> Bool,_ message:String){checks+=1;precondition(value(),message)}
let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
defer{try? FileManager.default.removeItem(at:directory)}
let store=OperBoxHistoryStore(directory:directory)
let scope=InventoryScope(connection:"adb",server:"CN",profile:"Default",account:"A/../x")
let own=OperBoxHistoryPayload.OwnedOperator(id:"amiya",own:true,name:"阿米娅\"\\\n",rarity:5,elite:1,level:50,potential:2)
let all=OperBoxHistoryPayload.Operator(id:"amiya",own:true,name:own.name,rarity:5)
let valid=OperBoxHistoryPayload(done:true,allOperators:[all],ownedOperators:[own])
let fixed=Date(timeIntervalSince1970:1700000000)
try store.save(valid,scope:scope,now:fixed)
let saved=try store.load(scope:scope)!
check(saved.operators==valid && saved.capturedAt==fixed && saved.scope==scope,"Exact received fields and capture identity persisted")
check(try! OperBoxHistoryStore(directory:directory).load(scope:scope)==saved,"Independent instance restores operator history")
let encoded=try JSONSerialization.jsonObject(with:JSONEncoder().encode(saved.operators.ownedOperators[0])) as! [String:Any]
check(Set(encoded.keys)==Set(["id","own","name","rarity","elite","level","potential"]),"Absent skill/mastery/module data not fabricated")
for other in [InventoryScope(connection:"other",server:"CN",profile:"Default",account:scope.account),InventoryScope(connection:"adb",server:"US",profile:"Default",account:scope.account),InventoryScope(connection:"adb",server:"CN",profile:"Other",account:scope.account),InventoryScope(connection:"adb",server:"CN",profile:"Default",account:"B")] {
 check(try! store.load(scope:other)==nil,"Account/server/connection/profile cannot share record")
}
let negative=OperBoxHistoryPayload.OwnedOperator(id:"amiya",own:true,name:"阿米娅",rarity:5,elite:1,level:-1,potential:2)
for bad in [OperBoxHistoryPayload(done:false,allOperators:[all],ownedOperators:[own]),.init(done:true,allOperators:[],ownedOperators:[]),.init(done:true,allOperators:[all,all],ownedOperators:[own]),.init(done:true,allOperators:[all],ownedOperators:[own,own]),.init(done:true,allOperators:[all],ownedOperators:[negative])] {
 do{try store.save(bad,scope:scope);preconditionFailure("Invalid/partial history accepted")}catch{checks+=1}
 check(try! store.load(scope:scope)==saved,"Rejected refresh preserves last complete snapshot")
}
let unbound=InventoryScope(connection:"adb",server:"CN",profile:"Default")
check(try! store.load(scope:unbound)==nil,"Unbound account never loads historical data")
do{try store.save(valid,scope:unbound);preconditionFailure("Unbound account saved")}catch{checks+=1}
let file=try HistoryFileIO.fileURL(scope:scope,directory:directory)
check(file.deletingLastPathComponent().path==directory.path,"Manual account label cannot escape directory")
var json=try JSONSerialization.jsonObject(with:Data(contentsOf:file)) as! [String:Any];json["schemaVersion"]=2
try JSONSerialization.data(withJSONObject:json).write(to:file)
do{_ = try store.load(scope:scope);preconditionFailure("Future schema accepted")}catch{checks+=1}
json["schemaVersion"]=1;var altered=json["scope"] as! [String:Any];altered["account"]="B";json["scope"]=altered
try JSONSerialization.data(withJSONObject:json).write(to:file)
do{_ = try store.load(scope:scope);preconditionFailure("Mismatched envelope accepted")}catch{checks+=1}
try Data("broken".utf8).write(to:file)
do{_ = try store.load(scope:scope);preconditionFailure("Corrupt data accepted")}catch{checks+=1}
let blocked=directory.appendingPathComponent("blocked");try Data().write(to:blocked)
do{try OperBoxHistoryStore(directory:blocked).save(valid,scope:scope);preconditionFailure("Write failure ignored")}catch{checks+=1}
print("PASS \(checks) historical operator storage assertions")

// MARK: - I04 一图流只读练度导入

func yituliuCheck(_ value:@autoclosure () -> Bool,_ message:String){checks+=1;precondition(value(),message)}

// 业务码 → 验证结论：200 成功、20010 仅写入、20027/未知码无效（WPF ParseValidationResult 同构）。
yituliuCheck(YituliuOperBoxService.parseValidation(.init(code:200,msg:nil,data:nil)) == .valid,"200 maps to valid")
yituliuCheck(YituliuOperBoxService.parseValidation(.init(code:20010,msg:"w",data:nil)) == .writeOnly,"20010 maps to writeOnly")
yituliuCheck(YituliuOperBoxService.parseValidation(.init(code:20027,msg:"bad",data:nil)) == .invalid,"20027 maps to invalid")
yituliuCheck(YituliuOperBoxService.parseValidation(.init(code:999,msg:nil,data:nil)) == .invalid,"unknown code maps to invalid")
yituliuCheck(YituliuOperBoxService.parseValidation(nil) == .invalid,"unparsable body maps to invalid")

// 目录加载：合成 battle_data.json，各语言名字段与缺省回退。
let resourceDir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory:true)
try FileManager.default.createDirectory(at:resourceDir,withIntermediateDirectories:true)
defer{try? FileManager.default.removeItem(at:resourceDir)}
let battleData:[String:Any]=["chars":[
  "char_002_amiya":["name":"阿米娅","name_en":"Amiya","name_jp":"アーミヤ","name_kr":"아미야","name_tw":"阿米婭","rarity":5],
  "char_143_ghost":["name":"幽灵鲨","name_en":"Specter","rarity":5],
  "char_999_old":["name":"过时干员","rarity":3]]]
try JSONSerialization.data(withJSONObject:battleData).write(to:resourceDir.appendingPathComponent("battle_data.json"))
let zh=OperatorCatalog.load(resourceDirectory:resourceDir,localeIdentifier:"zh-Hans")
yituliuCheck(zh.operators["char_002_amiya"]?.name=="阿米娅" && zh.operators["char_002_amiya"]?.rarity==5,"zh falls back to name")
yituliuCheck(OperatorCatalog.load(resourceDirectory:resourceDir,localeIdentifier:"en").operators["char_002_amiya"]?.name=="Amiya","en uses name_en")
yituliuCheck(OperatorCatalog.load(resourceDirectory:resourceDir,localeIdentifier:"ko").operators["char_002_amiya"]?.name=="아미야","ko uses name_kr")
yituliuCheck(OperatorCatalog.load(resourceDirectory:resourceDir,localeIdentifier:"zh-Hant").operators["char_002_amiya"]?.name=="阿米婭","zh-Hant uses name_tw")
yituliuCheck(OperatorCatalog.load(resourceDirectory:resourceDir,localeIdentifier:"ja").operators["char_143_ghost"]?.name=="幽灵鲨","missing locale field falls back to name")
yituliuCheck(OperatorCatalog.load(resourceDirectory:FileManager.default.temporaryDirectory,localeIdentifier:"en").operators.isEmpty,"missing battle_data yields empty catalog")
yituliuCheck(OperatorCatalog.load(resourceDirectory:nil,localeIdentifier:"en").operators.isEmpty,"nil directory yields empty catalog")

// 转换：本地表补名/星级，未知名跳过，越界行跳过，去重保留首个，skills/equips 丢弃。
let rows:[YituliuOperBoxService.OperatorInfo]=[
  .init(id:"char_002_amiya",level:60,evolvePhase:2,mainSkillLevel:7,potentialRank:6,skills:[.init(id:"skchr_amiya_2",level:3)],equips:[.init(id:"equip_002_amiya",type:"X",level:3)]),
  .init(id:"char_999_unknown",level:1,evolvePhase:0,mainSkillLevel:1,potentialRank:1,skills:nil,equips:nil),
  .init(id:"char_143_ghost",level:50,evolvePhase:1,mainSkillLevel:6,potentialRank:2,skills:nil,equips:nil),
  .init(id:"char_002_amiya",level:1,evolvePhase:0,mainSkillLevel:1,potentialRank:1,skills:nil,equips:nil),
  .init(id:"char_999_bad",level:-1,evolvePhase:0,mainSkillLevel:1,potentialRank:1,skills:nil,equips:nil),
  .init(id:"char_999_bad2",level:1,evolvePhase:3,mainSkillLevel:1,potentialRank:1,skills:nil,equips:nil),
  .init(id:"char_999_bad3",level:1,evolvePhase:0,mainSkillLevel:1,potentialRank:0,skills:nil,equips:nil),
]
let payload=YituliuOperBoxService.convert(rows,catalog:zh)
yituliuCheck(payload.done && payload.ownedOperators.count==2,"done with only usable rows")
// P16.2：一图流技能/模组随行携带（原"丢弃"断言已被 schema 扩展取代）。
yituliuCheck(payload.ownedOperators[0].elite==2 && payload.ownedOperators[0].level==60 && payload.ownedOperators[0].potential==6 && payload.ownedOperators[0].mainSkillLevel==7 && payload.ownedOperators[0].skills==[OperBoxHistoryPayload.Skill(id:"skchr_amiya_2",level:3)] && payload.ownedOperators[0].equips==[OperBoxHistoryPayload.Equip(id:"equip_002_amiya",type:"X",level:3)],"evolvePhase/potentialRank map and yituliu fields carry through")
yituliuCheck(payload.ownedOperators[1].name=="幽灵鲨" && payload.ownedOperators[1].elite==1 && payload.ownedOperators[1].potential==2,"unknown/out-of-range rows skipped")
yituliuCheck(payload.isValid,"converted payload passes snapshot validity")
let encodedOper=try! JSONSerialization.jsonObject(with:JSONEncoder().encode(payload.ownedOperators[0])) as! [String:Any]
yituliuCheck(Set(encodedOper.keys)==Set(["id","own","name","rarity","elite","level","potential","mainSkillLevel","skills","equips"]),"yituliu fields encode under exact keys (P16.2)")
yituliuCheck(YituliuOperBoxService.convert(rows,catalog:OperatorCatalog(operators:[:])).ownedOperators.isEmpty,"empty catalog converts to empty payload (noData path)")
yituliuCheck(YituliuOperBoxService.convert([],catalog:zh).ownedOperators.isEmpty,"empty yituliu data converts to empty payload (noData path)")

// 落盘等价：转换结果可直接经既有快照存储往返。
try store.save(payload,scope:scope,now:fixed)
yituliuCheck(try! store.load(scope:scope)!.operators==payload,"yituliu payload round-trips through OperBoxHistoryStore")
print("PASS: yituliu validation codes, catalog locales, conversion skips and store equivalence (\(checks) total checks)")

// MARK: - I04 fetch 路径（URLProtocol 桩，离线验证真实客户端语义）

final class StubYituliuProtocol: URLProtocol {
  nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    let (status, data) = Self.handler!(request)
    let http = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
    client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: data)
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}

let stubbedSession: URLSession = {
  let config = URLSessionConfiguration.ephemeral
  config.protocolClasses = [StubYituliuProtocol.self]
  return URLSession(configuration: config)
}()
let service = YituliuOperBoxService()

func fetchAwait(_ token: String) async -> (YituliuOperBoxService.TokenValidationResult, [YituliuOperBoxService.OperatorInfo]?) {
  await service.fetchOperatorInfo(token: token, session: stubbedSession, url: URL(string: "https://stub.local/operator/info")!)
}

// 200：携带 Authorization 头并解析 data 列表。
var capturedHeader: String?
StubYituliuProtocol.handler = { request in
  capturedHeader = request.value(forHTTPHeaderField: "Authorization")
  return (200, try! JSONSerialization.data(withJSONObject: ["code":200,"msg":"","data":[["id":"char_002_amiya","level":60,"evolvePhase":2,"mainSkillLevel":7,"potentialRank":3]]]))
}
let (validVerdict, validData) = await fetchAwait("token-abc")
yituliuCheck(validVerdict == .valid && capturedHeader == "token-abc", "fetch sends Authorization header")
yituliuCheck(validData?.count == 1 && validData?[0].id == "char_002_amiya", "fetch parses operator list")

// 业务码照实映射；data 不外泄。
for (code, expected) in [(20010, YituliuOperBoxService.TokenValidationResult.writeOnly), (20027, .invalid), (7, .invalid)] {
  StubYituliuProtocol.handler = { _ in (200, try! JSONSerialization.data(withJSONObject: ["code":code,"msg":"x"])) }
  let (verdict, data) = await fetchAwait("t")
  yituliuCheck(verdict == expected && data == nil, "code \(code) maps without leaking data")
}

// HTTP 500 与连接失败 → networkError；200 坏 JSON → 业务码缺失按 invalid。
StubYituliuProtocol.handler = { _ in (500, Data()) }
let (http500Verdict, _) = await fetchAwait("t")
yituliuCheck(http500Verdict == .networkError, "HTTP 500 maps to networkError")
let (badVerdict, _) = await service.fetchOperatorInfo(token: "t", session: stubbedSession, url: URL(string: "https://unreachable.invalid/api")!)
yituliuCheck(badVerdict == .networkError, "connection failure maps to networkError")
StubYituliuProtocol.handler = { _ in (200, Data("not-json".utf8)) }
let (malformedVerdict, _) = await fetchAwait("t")
yituliuCheck(malformedVerdict == .invalid, "malformed body maps to invalid")
print("PASS: yituliu fetch path offline semantics (\(checks) total checks)")

// MARK: - P16.2 快照附加字段（一图流技能/专精/模组，schema v1 additive）

let skills=[OperBoxHistoryPayload.Skill(id:"skchr_amiya_2",level:3),OperBoxHistoryPayload.Skill(id:"skchr_amiya_1",level:0)]
let equips=[OperBoxHistoryPayload.Equip(id:"equip_002_amiya",type:"X",level:3),OperBoxHistoryPayload.Equip(id:"equip_002_amiya_b",type:"Y",level:0)]
let yituliuOper=OperBoxHistoryPayload.OwnedOperator(id:"char_002_amiya",own:true,name:"阿米娅",rarity:5,elite:2,level:60,potential:6,mainSkillLevel:7,skills:skills,equips:equips)
let yituliuAll=OperBoxHistoryPayload.Operator(id:"char_002_amiya",own:true,name:"阿米娅",rarity:5)
let yituliuPayload=OperBoxHistoryPayload(done:true,allOperators:[yituliuAll],ownedOperators:[yituliuOper])
yituliuCheck(yituliuPayload.isValid,"yituliu extended payload passes validity")
try store.save(yituliuPayload,scope:scope,now:fixed,source:"yituliu")
let loadedYituliu=try! store.load(scope:scope)!
yituliuCheck(loadedYituliu.source=="yituliu" && loadedYituliu.operators.ownedOperators[0].mainSkillLevel==7,"source tag and main skill round-trip")
yituliuCheck(loadedYituliu.operators.ownedOperators[0].skills==skills && loadedYituliu.operators.ownedOperators[0].equips==equips,"skills/equips round-trip in order")
// 识别路径构造仍零参数差异（缺省 nil），编码省略空可选键。
let baseOper=OperBoxHistoryPayload.OwnedOperator(id:"char_143_ghost",own:true,name:"幽灵鲨",rarity:5,elite:1,level:50,potential:2)
yituliuCheck(baseOper.mainSkillLevel==nil && baseOper.skills==nil && baseOper.equips==nil,"recognition path keeps optional fields nil by default")
let baseEncoded=try! JSONSerialization.jsonObject(with:JSONEncoder().encode(baseOper)) as! [String:Any]
yituliuCheck(Set(baseEncoded.keys)==Set(["id","own","name","rarity","elite","level","potential"]),"nil optionals stay absent from encoded face")
let extendedEncoded=try! JSONSerialization.jsonObject(with:JSONEncoder().encode(yituliuOper)) as! [String:Any]
yituliuCheck(Set(extendedEncoded.keys)==Set(["id","own","name","rarity","elite","level","potential","mainSkillLevel","skills","equips"]),"present optionals encode under exact keys")
// 越界值拒绝：专精 4、主技能 0、模组负级。
for bad in [
  OperBoxHistoryPayload.OwnedOperator(id:"x",own:true,name:"x",rarity:5,elite:2,level:60,potential:6,mainSkillLevel:0),
  OperBoxHistoryPayload.OwnedOperator(id:"x",own:true,name:"x",rarity:5,elite:2,level:60,potential:6,skills:[.init(id:"s",level:4)]),
  OperBoxHistoryPayload.OwnedOperator(id:"x",own:true,name:"x",rarity:5,elite:2,level:60,potential:6,equips:[.init(id:"e",type:"X",level:-1)]),
] {
  do{try store.save(.init(done:true,allOperators:[yituliuAll],ownedOperators:[bad]),scope:scope);preconditionFailure("Out-of-range yituliu field accepted")}catch{checks+=1}
}
yituliuCheck(try! store.load(scope:scope)!.operators.ownedOperators[0].skills==skills,"Rejected refresh preserves last extended snapshot")
print("PASS P16.2 extended snapshot schema: source tag, optional round-trip, validity bounds (\(checks) total checks)")
