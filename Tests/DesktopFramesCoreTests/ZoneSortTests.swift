import Foundation
import Testing
@testable import DesktopFramesCore

@Suite("分区自动排序（只改显示顺序，不碰文件）")
struct ZoneSortTests {
    private let zh = Locale(identifier: "zh-Hans")
    private let en = Locale(identifier: "en_US")

    private func item(_ name: String, kind: ZoneItemKind = .file) -> ZoneItem {
        ZoneItem(url: URL(fileURLWithPath: "/tmp/zone-sort/\(name)"), kind: kind)
    }

    private func names(_ items: [ZoneItem]) -> [String] { items.map(ZoneSorter.sortName) }

    @Test("名称：数字按大小（file2 在 file10 前），不分大小写")
    func naturalNumbers() {
        let items = ["file10.txt", "File1.txt", "file2.txt", "b", "Apple"].map { item($0) }
        let sorted = ZoneSorter.sorted(items, by: .name, locale: en)
        #expect(names(sorted) == ["Apple", "b", "File1.txt", "file2.txt", "file10.txt"])
    }

    @Test("名称：中文系统下汉字按拼音")
    func pinyin() {
        let items = ["中国", "报告", "阿里"].map { item($0) }
        #expect(names(ZoneSorter.sorted(items, by: .name, locale: zh)) == ["阿里", "报告", "中国"])
    }

    @Test("名称倒序：Z→A")
    func nameReversed() {
        let items = ["a2", "a10", "a1"].map { item($0) }
        #expect(names(ZoneSorter.sorted(items, by: .name, reversed: true, locale: en)) == ["a10", "a2", "a1"])
    }

    @Test("App 按去掉 .app 的名字排；有显示名用显示名")
    func displayNames() {
        var custom = item("zzz.txt")
        custom.displayName = "Aaa"
        let items = [item("Safari.app", kind: .application), custom, item("Notes.app", kind: .application)]
        #expect(names(ZoneSorter.sorted(items, by: .name, locale: en)) == ["Aaa", "Notes", "Safari"])
    }

    @Test("修改日期默认新的在前；倒序旧的在前；拿不到日期的永远在最后")
    func dates() {
        let a = item("a"), b = item("b"), c = item("c"), gone = item("gone")
        let dates: [UUID: Date] = [
            a.id: Date(timeIntervalSince1970: 100),
            b.id: Date(timeIntervalSince1970: 300),
            c.id: Date(timeIntervalSince1970: 200),
        ]
        let keys: (ZoneItem) -> ZoneSortKeys = { ZoneSortKeys(modified: dates[$0.id]) }
        let items = [gone, a, b, c]
        #expect(names(ZoneSorter.sorted(items, by: .dateModified, locale: en, keys: keys)) == ["b", "c", "a", "gone"])
        #expect(names(ZoneSorter.sorted(items, by: .dateModified, reversed: true, locale: en, keys: keys)) == ["a", "c", "b", "gone"])
    }

    @Test("大小 / 种类并列时按名字排，再并列保持原顺序（稳定）")
    func tieBreak() {
        let items = ["b", "a", "c"].map { item($0) }
        let same: (ZoneItem) -> ZoneSortKeys = { _ in ZoneSortKeys(kind: "文本", size: 5) }
        #expect(names(ZoneSorter.sorted(items, by: .size, locale: en, keys: same)) == ["a", "b", "c"])
        #expect(names(ZoneSorter.sorted(items, by: .kind, locale: en, keys: same)) == ["a", "b", "c"])
        let twins = [item("x"), item("x")]
        #expect(ZoneSorter.sorted(twins, by: .name, locale: en).map(\.id) == twins.map(\.id))
    }

    @Test("手动排列原样返回")
    func manualKeepsOrder() {
        let items = ["c", "a", "b"].map { item($0) }
        #expect(ZoneSorter.sorted(items, by: .manual).map(\.id) == items.map(\.id))
    }

    @Test("读真实文件的排序信息：只读，不改文件")
    func readsRealFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ZoneSortTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let small = dir.appendingPathComponent("small.txt"), big = dir.appendingPathComponent("big.txt")
        try Data(count: 10).write(to: small)
        try Data(count: 5000).write(to: big)
        let before = try FileManager.default.attributesOfItem(atPath: small.path)[.modificationDate] as? Date
        let items = [ZoneItem(url: small, kind: .file), ZoneItem(url: big, kind: .file)]
        #expect(ZoneSorter.sorted(items, by: .size).map(\.url) == [big, small])
        let after = try FileManager.default.attributesOfItem(atPath: small.path)[.modificationDate] as? Date
        #expect(before == after)
        #expect(FileManager.default.fileExists(atPath: small.path))
    }

    @Test("排序设置存盘往返；旧存档 / 不认识的排序方式按手动排列读")
    func codable() throws {
        var zone = Zone(name: "z", kind: .virtual)
        zone.sortOrder = .dateModified
        zone.sortReversed = true
        let data = try JSONEncoder().encode(zone)
        let back = try JSONDecoder().decode(Zone.self, from: data)
        #expect(back.sortOrder == .dateModified)
        #expect(back.sortReversed)

        var json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        json["sortOrder"] = "lastOpened-future"
        let future = try JSONDecoder().decode(Zone.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(future.sortOrder == .manual)
        json.removeValue(forKey: "sortOrder")
        json.removeValue(forKey: "sortReversed")
        let old = try JSONDecoder().decode(Zone.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.sortOrder == .manual)
        #expect(!old.sortReversed)
    }

    @Test("开启 / 关闭自动排序不改保存的手动顺序；整理一次会改手动顺序")
    @MainActor
    func modelKeepsManualOrder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ZoneSortModel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ZoneStore(layoutFile: root.appendingPathComponent("layout.json"),
                              backupsDirectory: root.appendingPathComponent("Backups"))
        let model = AppModel(store: store, screens: [])
        let zone = model.createZone(kind: .virtual, name: "z", frame: ZoneFrame(), screenID: "1", backingFolderPath: nil)
        let items = ["c10", "c2", "a"].map { item($0) }
        for it in items { model.addItem(it, to: zone.id) }
        let manual = items.map(\.id)

        model.setSortOrder(zoneID: zone.id, order: .name)
        model.setSortReversed(zoneID: zone.id, reversed: true)
        #expect(model.zone(id: zone.id)?.items.map(\.id) == manual)
        // 换排序方式时倒序复位
        model.setSortOrder(zoneID: zone.id, order: .size)
        #expect(model.zone(id: zone.id)?.sortReversed == false)
        model.setSortOrder(zoneID: zone.id, order: .manual)
        #expect(model.zone(id: zone.id)?.items.map(\.id) == manual)

        model.arrangeOnce(zoneID: zone.id, by: .name)
        #expect(model.zone(id: zone.id)?.items.map(ZoneSorter.sortName) == ["a", "c2", "c10"])
        #expect(model.zone(id: zone.id)?.sortOrder == .manual)
    }
}
