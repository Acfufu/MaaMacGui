//
//  GitHub.swift
//  MAA
//
//  Created by hguandl on 2025/2/5.
//

import Foundation

public struct GitHub: Sendable {
    private let repo: String

    public init(repo: String) {
        self.repo = repo
    }

    public func rawURL(ref: String, path: String) -> URL? {
        URL(string: "https://github.com/\(repo)/raw/refs/\(ref)/\(path)")
    }

    public func archiveURL(ref: String) -> URL? {
        URL(string: "https://github.com/\(repo)/archive/refs/\(ref).zip")
    }

    public struct Version: Decodable {
        public let last_updated: String
    }
}

extension GitHub {
    /// P27/U08+D06: 会话（代理）与 token（限流）可注入；缺省保持系统默认。
    public func query(session: URLSession = .shared, token: String? = nil) async throws -> Version {
        let url = rawURL(ref: "heads/main", path: "resource/version.json")!
        var request = URLRequest(url: url)
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, resp) = try await session.data(for: request)
        if let resp = resp as? HTTPURLResponse {
            switch resp.statusCode {
            case 403: throw MAAResourceChannel.Error.forbidden
            case 429: throw MAAResourceChannel.Error.rateExceeded
            default: break
            }
        }
        let version = try JSONDecoder().decode(Version.self, from: data)
        return version
    }
}
