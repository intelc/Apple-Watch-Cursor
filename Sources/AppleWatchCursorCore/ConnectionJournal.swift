import Foundation

/// Bounded, local connection diagnostics. Never records pairing codes, session tokens, or sensor data.
@MainActor
public final class ConnectionJournal {
    private struct Entry: Codable {
        let time: String
        let uptime: Double
        let component: String
        let event: String
        let detail: String
    }
    private let component: String
    private let url: URL
    private var entries: [Entry] = []
    public init(component: String) {
        self.component = component
        #if os(watchOS)
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        #else
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Apple-Watch-Cursor", isDirectory: true)
        #endif
        url = root.appendingPathComponent("connection-events.json")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = Array(saved.suffix(100))
        }
    }
    public func record(_ event: String, detail: String = "") {
        entries.append(.init(time: ISO8601DateFormatter().string(from: Date()),
                             uptime: ProcessInfo.processInfo.systemUptime, component: component, event: event, detail: detail))
        entries = Array(entries.suffix(100))
        if let data = try? JSONEncoder().encode(entries) { try? data.write(to: url, options: .atomic) }
    }
}
