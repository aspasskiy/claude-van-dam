import Foundation

/// The app's name and version, for user-facing text, the User-Agent and exports.
public enum AppInfo {
    public static let name = "Claude Van Dam"
    /// Lowercase form for the User-Agent, export tags and file names.
    public static let slug = "claude-van-dam"
    /// From the bundle's Info.plist; "dev" for bare builds (`swift run`, the CLI).
    public static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}

/// Blocking HTTP for code that already runs off the main thread.
enum HTTP {
    static let userAgent = "\(AppInfo.slug)/\(AppInfo.version)"

    struct Response {
        /// 0 when no HTTP response arrived.
        let status: Int
        let data: Data?
        let http: HTTPURLResponse?
        let error: URLError?
        var json: [String: Any]? { data.flatMap(JSONFiles.object) }
    }

    static func send(_ request: URLRequest) -> Response {
        var request = request
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let done = DispatchSemaphore(value: 0)
        let response = Handoff(Response(status: 0, data: nil, http: nil, error: nil))
        URLSession.shared.dataTask(with: request) { data, r, error in
            let http = r as? HTTPURLResponse
            response.value = Response(status: http?.statusCode ?? 0, data: data, http: http, error: error as? URLError)
            done.signal()
        }.resume()
        done.wait()
        return response.value
    }
}
