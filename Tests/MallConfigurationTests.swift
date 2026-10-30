import Foundation

@main
struct MallConfigurationTests {
    static func main() throws {
        let formatter = ISO8601DateFormatter()
        var checks = 0
        func check(_ condition: Bool, _ message: String) {
            guard condition else {
                fputs("FAIL: \(message)\n", stderr)
                exit(1)
            }
            checks += 1
        }

        for channel in MAAClientChannel.allCases {
            let reset = channel.calendar.nextReset(after: formatter.date(from: "2026-01-15T00:00:00Z")!)
            let before = reset.addingTimeInterval(-0.001)
            let after = reset.addingTimeInterval(0.001)
            for (creditEnabled, visitsEnabled) in [(true, true), (true, false), (false, true), (false, false)] {
                for (fightCompleted, visitLimited) in [(true, true), (true, false), (false, true), (false, false)] {
                    for now in [before, after] {
                        var config = try JSONDecoder().decode(MallConfiguration.self, from: Data("{}".utf8))
                        config.clientChannel = channel
                        config.creditFight = creditEnabled
                        config.visitFriends = visitsEnabled
                        config.shopping = false
                        config.formationIndex = 3
                        config.creditFightDate = fightCompleted ? before : .distantPast
                        config.friendVisitDate = visitLimited ? before : .distantPast

                        // Parameter generation must snapshot the clock exactly once. Rig the clock
                        // so the single read yields `now`, and keep the trailing entries as trap
                        // dates: any extra read would cross the reset and fail the checks below.
                        MallTestClock.dates = [now, now, after]
                        MallTestClock.reads = 0
                        let data = try JSONEncoder().encode(config.params)
                        let params = try JSONSerialization.jsonObject(with: data) as! [String: Any]
                        let expectedFight = creditEnabled && (!fightCompleted || now == after)
                        let expectedVisit = visitsEnabled && (!visitLimited || now == after)
                        let context =
                            "\(channel.rawValue) credit=\(creditEnabled)/\(fightCompleted) visits=\(visitsEnabled)/\(visitLimited) now=\(now)"
                        check(params["credit_fight"] as? Bool == expectedFight, "\(context): credit fight")
                        check(params["visit_friends"] as? Bool == expectedVisit, "\(context): friend visit")
                        check(
                            (params["formation_index"] != nil) == expectedFight,
                            "\(context): formation must be present exactly when a fight is scheduled")
                        if expectedFight {
                            check(params["formation_index"] as? Int == 3, "\(context): selected formation")
                        }
                        check(params["shopping"] as? Bool == false, "\(context): shopping changed")
                        check(MallTestClock.reads == 1, "\(context): parameter generation must read the clock once")
                    }
                }
            }
        }
        print("Passed \(checks) Mall parameter checks across all six channels")
    }
}
