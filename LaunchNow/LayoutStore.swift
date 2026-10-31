import Foundation

// MARK: - JSON 持久化（替代 SwiftData）
//
// Command Line Tools 不带 SwiftData 的宏插件，@Model 编译不了。
// 这里只实现 AppStore 实际用到的那部分接口（fetch / insert / delete / save），
// 名字与 SwiftData 保持一致，AppStore 里的持久化代码无需改动；
// 数据落在 Application Support/LaunchNow/layout.json。

/// 与 SwiftData 同名的取数描述，只支持排序。
struct FetchDescriptor<T> {
    var sortBy: [SortDescriptor<T>]

    init(sortBy: [SortDescriptor<T>] = []) {
        self.sortBy = sortBy
    }
}

/// 布局存储：内存中持有全部记录，save() 时整份写回 JSON。
final class ModelContext {
    static let fileName = "layout.json"

    private struct Snapshot: Codable {
        var version = 1
        var pageEntries: [PageEntryData] = []
        var topItems: [TopItemData] = []
    }

    let url: URL
    private var pageEntries: [PageEntryData] = []
    private var topItems: [TopItemData] = []

    init(url: URL) {
        self.url = url
        if let data = try? Data(contentsOf: url),
           let snapshot = try? Self.decoder.decode(Snapshot.self, from: data) {
            pageEntries = snapshot.pageEntries
            topItems = snapshot.topItems
        }
    }

    func fetch<T>(_ descriptor: FetchDescriptor<T>) throws -> [T] {
        let rows: [T]
        if let pages = pageEntries as? [T] {
            rows = pages
        } else if let tops = topItems as? [T] {
            rows = tops
        } else {
            rows = []
        }
        return descriptor.sortBy.isEmpty ? rows : rows.sorted(using: descriptor.sortBy)
    }

    // 主键唯一（对应原来的 @Attribute(.unique)）：同键插入即替换
    func insert(_ row: PageEntryData) {
        pageEntries.removeAll { $0.slotId == row.slotId }
        pageEntries.append(row)
    }

    func insert(_ row: TopItemData) {
        topItems.removeAll { $0.id == row.id }
        topItems.append(row)
    }

    func delete(_ row: PageEntryData) {
        pageEntries.removeAll { $0 === row }
    }

    func delete(_ row: TopItemData) {
        topItems.removeAll { $0 === row }
    }

    func save() throws {
        let data = try Self.encoder.encode(Snapshot(pageEntries: pageEntries, topItems: topItems))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
