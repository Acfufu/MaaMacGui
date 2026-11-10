//
//  MAAInfrast.swift
//  MAA
//
//  Created by hguandl on 20/4/2023.
//

import SwiftUI

struct MAAInfrast: Codable, Hashable {
    let title: String?
    let description: String?
    let plans: [Plan]

    struct Plan: Codable, Hashable {
        let name: String?
        let description: String?
        let description_post: String?
        let period: [[String]]?
    }
}

extension MAAInfrast {
    init(path: String) throws {
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        self = try JSONDecoder().decode(MAAInfrast.self, from: data)
    }

    var hasPeriods: Bool {
        plans.contains { $0.period?.isEmpty == false }
    }

    var hasMixedPeriods: Bool {
        hasPeriods && plans.contains { $0.period?.isEmpty != false }
    }

    var planList: some View {
        ForEach(Array(plans.enumerated()), id: \.offset) {
            Text($0.element.name ?? "\($0.offset)").tag($0.offset)
        }
    }
}
