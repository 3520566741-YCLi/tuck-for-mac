import Foundation
import Testing
@testable import DesktopFramesCore

@Suite("每个分区单独的玻璃质感")
struct ZoneGlassOverrideTests {

    @Test("旧存档没有质感字段：读出来全是 nil（跟随默认），其它外观不变")
    func oldLayoutDecodes() throws {
        let json = #"{"tint":"classicBlue20","opacity":0.5,"collapsed":true}"#
        let a = try JSONDecoder().decode(ZoneAppearance.self, from: Data(json.utf8))
        #expect(a.tint == "classicBlue20")
        #expect(a.opacity == 0.5)
        #expect(a.collapsed)
        #expect(a.glassStyle == nil && a.glassEdge == nil && a.glassRefraction == nil)
    }

    @Test("设了的值能存能读；nil 不写进文件")
    func roundTrip() throws {
        let a = ZoneAppearance(glassStyle: "frosted", glassRefraction: "fluted")
        let data = try JSONEncoder().encode(a)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("glassEdge"))
        let b = try JSONDecoder().decode(ZoneAppearance.self, from: data)
        #expect(b == a)
    }

    @Test("AppModel 设置 / 清除覆盖项，只影响那一个分区，并落盘")
    @MainActor
    func setAndClear() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GlassOverride-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ZoneStore(layoutFile: root.appendingPathComponent("layout.json"), backupsDirectory: root.appendingPathComponent("Backups"))
        let model = AppModel(store: store, screens: [])
        let z1 = model.createZone(kind: .virtual, name: "一", frame: ZoneFrame(), screenID: "1", backingFolderPath: nil)
        let z2 = model.createZone(kind: .virtual, name: "二", frame: ZoneFrame(x: 500), screenID: "1", backingFolderPath: nil)

        model.setGlassOverride(zoneID: z1.id, .refraction, value: "fluted")
        model.setGlassOverride(zoneID: z1.id, .style, value: "frosted")
        #expect(model.zone(id: z1.id)?.appearance.glassRefraction == "fluted")
        #expect(model.zone(id: z2.id)?.appearance.glassRefraction == nil)

        model.setGlassOverride(zoneID: z1.id, .style, value: nil)
        #expect(model.zone(id: z1.id)?.appearance.glassStyle == nil)

        model.persistNow()
        let saved = store.load().document
        #expect(saved.zones.first { $0.id == z1.id }?.appearance.glassRefraction == "fluted")
        #expect(saved.zones.first { $0.id == z2.id }?.appearance.glassRefraction == nil)
    }

    @Test("菜单栏改总设置：所有分区这一项都清回跟随总设置，其它项不动")
    @MainActor
    func clearAll() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GlassClear-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ZoneStore(layoutFile: root.appendingPathComponent("layout.json"), backupsDirectory: root.appendingPathComponent("Backups"))
        let model = AppModel(store: store, screens: [])
        let a = model.createZone(kind: .virtual, name: "a", frame: ZoneFrame(), screenID: "1", backingFolderPath: nil)
        let b = model.createZone(kind: .virtual, name: "b", frame: ZoneFrame(x: 500), screenID: "1", backingFolderPath: nil)
        model.setGlassOverride(zoneID: a.id, .refraction, value: "fluted")
        model.setGlassOverride(zoneID: b.id, .refraction, value: "off")
        model.setGlassOverride(zoneID: b.id, .style, value: "dark")
        model.clearGlassOverrides(.refraction)
        #expect(model.zone(id: a.id)?.appearance.glassRefraction == nil)
        #expect(model.zone(id: b.id)?.appearance.glassRefraction == nil)
        #expect(model.zone(id: b.id)?.appearance.glassStyle == "dark")
    }
}
