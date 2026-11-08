// 生成 Tuck 的 Icon Composer 分层图标（Tuck.icon）：背景渐变由 icon.json 给出，
// 前景三层透明 PNG（玻璃框 / 收起的胶囊 / 文件），系统会自动加液态玻璃高光与深浅色、着色变体。
// 用法：swift Support/AppIcon/generate-icon-layers.swift <Tuck.icon 目录>
import AppKit
import CoreGraphics

let iconDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Tuck.icon")
let assets = iconDir.appendingPathComponent("Assets", isDirectory: true)
try? FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
let cs = CGColorSpace(name: CGColorSpace.sRGB)!

func layer(_ name: String, _ draw: (CGContext) -> Void) {
    let ctx = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0,
                        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    draw(ctx)
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try! rep.representation(using: .png, properties: [:])!.write(to: assets.appendingPathComponent(name))
}

func white(_ a: CGFloat) -> CGColor { CGColor(srgbRed: 1, green: 1, blue: 1, alpha: a) }

// 1) 玻璃框（展开的分区）：实心白形状，由系统渲染成玻璃
layer("frame.png") { ctx in
    ctx.addPath(CGPath(roundedRect: CGRect(x: 196, y: 170, width: 632, height: 470), cornerWidth: 96, cornerHeight: 96, transform: nil))
    ctx.setFillColor(white(0.30)); ctx.fillPath() // 低不透明度 = 更通透的清透玻璃
}

// 2) 收起的胶囊（上方）：同样是玻璃
layer("capsule.png") { ctx in
    ctx.addPath(CGPath(roundedRect: CGRect(x: 196, y: 712, width: 632, height: 128), cornerWidth: 64, cornerHeight: 64, transform: nil))
    ctx.setFillColor(white(0.42)); ctx.fillPath()
}

// 3) 文件：框里 2×2 的小块，上排正在“往上收”（更小、更淡），体现收起动作
layer("files.png") { ctx in
    let tiles: [(CGRect, CGFloat)] = [
        (CGRect(x: 276, y: 236, width: 196, height: 150), 1.0),
        (CGRect(x: 552, y: 236, width: 196, height: 150), 1.0),
        (CGRect(x: 300, y: 438, width: 148, height: 112), 0.75),
        (CGRect(x: 576, y: 438, width: 148, height: 112), 0.75),
    ]
    for (r, a) in tiles {
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: 34, cornerHeight: 34, transform: nil))
        ctx.setFillColor(white(a)); ctx.fillPath()
    }
    // 胶囊里的色点和名称条（让它一眼看出是“收起的分区”）
    ctx.setFillColor(white(1))
    ctx.fillEllipse(in: CGRect(x: 252, y: 756, width: 40, height: 40))
    ctx.addPath(CGPath(roundedRect: CGRect(x: 318, y: 762, width: 300, height: 28), cornerWidth: 14, cornerHeight: 14, transform: nil))
    ctx.fillPath()
    // 收起箭头 ︿（在胶囊下沿，指向胶囊）
    ctx.setStrokeColor(white(0.95)); ctx.setLineWidth(22); ctx.setLineCap(.round); ctx.setLineJoin(.round)
    ctx.move(to: CGPoint(x: 470, y: 664)); ctx.addLine(to: CGPoint(x: 512, y: 692)); ctx.addLine(to: CGPoint(x: 554, y: 664))
    ctx.strokePath()
}

let json = """
{
  "fill" : {
    "linear-gradient" : [
      "srgb:0.45490,0.39608,0.94902,1.00000",
      "srgb:0.09412,0.69020,0.69804,1.00000"
    ],
    "orientation" : { "start" : { "x" : 0.2, "y" : 0 }, "stop" : { "x" : 0.8, "y" : 1 } }
  },
  "groups" : [
    {
      "name" : "files",
      "layers" : [ { "image-name" : "files.png", "name" : "files", "glass" : false } ],
      "shadow" : { "kind" : "neutral", "opacity" : 0.35 },
      "translucency" : { "enabled" : false, "value" : 0 }
    },
    {
      "name" : "glass",
      "layers" : [
        { "image-name" : "capsule.png", "name" : "capsule", "glass" : true },
        { "image-name" : "frame.png", "name" : "frame", "glass" : true }
      ],
      "shadow" : { "kind" : "neutral", "opacity" : 0.5 },
      "translucency" : { "enabled" : true, "value" : 0.55 },
      "specular" : true
    }
  ],
  "supported-platforms" : { "squares" : [ "macOS" ] }
}
"""
try! json.write(to: iconDir.appendingPathComponent("icon.json"), atomically: true, encoding: .utf8)
print("ok")
