import Foundation

/// A single captured HTTP request/response entry in HAR format.
struct HAREntry: Sendable {
    let startedDateTime: Date
    let method: String
    let url: String
    let httpVersion: String
    let requestHeaders: [(name: String, value: String)]
    let responseStatus: Int
    let responseStatusText: String
    let responseHeaders: [(name: String, value: String)]
    let responseBodySize: Int64
    let timings: HARTimings
    /// Source of this entry (relay proxy vs. injected JS)
    let source: Source

    enum Source: String, Sendable {
        case relay
        case jsIntercept = "js_intercept"
    }
}

struct HARTimings: Sendable {
    let connect: TimeInterval
    let send: TimeInterval
    let wait: TimeInterval
    let receive: TimeInterval

    var total: TimeInterval { connect + send + wait + receive }
}

/// Records HTTP request/response metadata for HAR 1.2 export.
/// Thread-safe: all mutations go through the internal serial queue.
class BrowserHARRecorder {
    private let queue = DispatchQueue(label: "com.trident.har-recorder")
    private var _entries: [HAREntry] = []
    private var _isRecording: Bool = false

    var isRecording: Bool {
        queue.sync { _isRecording }
    }

    var entryCount: Int {
        queue.sync { _entries.count }
    }

    func start() {
        queue.sync {
            _isRecording = true
            _entries.removeAll()
        }
    }

    func stop() {
        queue.sync { _isRecording = false }
    }

    func clear() {
        queue.sync { _entries.removeAll() }
    }

    func append(_ entry: HAREntry) {
        queue.sync {
            guard _isRecording else { return }
            _entries.append(entry)
        }
    }

    /// Export as HAR 1.2 JSON dictionary.
    func exportHAR() -> [String: Any] {
        let entries: [HAREntry] = queue.sync { _entries }
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let harEntries: [[String: Any]] = entries.map { entry in
            let requestHeaders = entry.requestHeaders.map { ["name": $0.name, "value": $0.value] }
            let responseHeaders = entry.responseHeaders.map { ["name": $0.name, "value": $0.value] }

            return [
                "startedDateTime": isoFormatter.string(from: entry.startedDateTime),
                "time": entry.timings.total * 1000,
                "request": [
                    "method": entry.method,
                    "url": entry.url,
                    "httpVersion": entry.httpVersion,
                    "headers": requestHeaders,
                    "queryString": [] as [[String: Any]],
                    "cookies": [] as [[String: Any]],
                    "headersSize": -1,
                    "bodySize": -1,
                ] as [String: Any],
                "response": [
                    "status": entry.responseStatus,
                    "statusText": entry.responseStatusText,
                    "httpVersion": entry.httpVersion,
                    "headers": responseHeaders,
                    "cookies": [] as [[String: Any]],
                    "redirectURL": "",
                    "headersSize": -1,
                    "bodySize": entry.responseBodySize,
                    "content": [
                        "size": entry.responseBodySize,
                        "mimeType": "",
                    ],
                ] as [String: Any],
                "timings": [
                    "connect": entry.timings.connect * 1000,
                    "send": entry.timings.send * 1000,
                    "wait": entry.timings.wait * 1000,
                    "receive": entry.timings.receive * 1000,
                ],
                "cache": [:] as [String: Any],
                "_source": entry.source.rawValue,
            ]
        }

        return [
            "log": [
                "version": "1.2",
                "creator": [
                    "name": "Trident Browser",
                    "version": "1.0",
                ],
                "entries": harEntries,
            ]
        ]
    }
}
