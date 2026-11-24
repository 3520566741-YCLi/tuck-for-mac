import Accelerate
import CoreGraphics
import Foundation

/// 玻璃光学：把分区后面的壁纸按真实玻璃的方式重新采样（只依赖 CoreGraphics / Accelerate，后台线程调用）。
///
/// 和上一版的区别（上一版看着像“条纹贴图”）：
/// - 光栅玻璃：每条棱是一根真正的柱面透镜。按斯涅尔定律算每一列的折射偏移，棱里看到的是更宽一片背景
///   被压缩、左右翻过来的样子（真实长虹玻璃的样子），而不是每条棱只取一小点颜色拉成一条竖纹；
///   明暗（受光高光、棱边的暗线、菲涅尔反光）按棱的法线算进图里，不再叠一张平铺的明暗贴图。
/// - 边缘拉伸：边缘截面是凸的超椭圆（squircle）倒角，按斯涅尔定律从倒角斜率算位移，越靠边越往里取、
///   再加一点色散（红蓝分开）和受光高光。
/// - 磨砂：先把背景糊一下再折射（光先被磨砂面打散，再被玻璃形状弯折），棱和倒角的形状保持清楚，
///   不会像以前那样整张图一起糊成一片竖条。
/// 参考：kube.io《Liquid Glass in the Browser》的凸 squircle 倒角 + 斯涅尔位移；Paper Shaders（Apache-2.0）
/// 的 Fluted Glass 参数（棱宽 / 扭曲 / 高光）；Hla-aung/liquid-glass（MIT）的一维光线追踪查表。全部原生重写。
///
/// 只在分区停下来、改大小、换壁纸时算一次；光栅每一列的偏移和明暗只算一遍（和行无关），边缘模式只算边缘一圈。
enum GlassOptics {
    enum Mode: Sendable { case edge, fluted }

    /// 一组光学参数（对比方案就是几组不同的参数）。长度单位都是点（pt），内部乘以 scale。
    struct Params: Sendable {
        /// 棱宽
        var ribWidth: Double
        /// 透镜强度：棱边缘的偏移是棱宽的多少倍。0.5 = 整条棱只看到一个点（太强）；>0.5 越大，翻折看到的范围越宽。
        var lensReach: Double
        /// 色散：红 / 蓝通道偏移相差的比例
        var dispersion: Double
        /// 棱的受光高光强度（0…1）
        var ribSpecular: Double
        /// 棱交界处暗线强度（0…1）
        var seamShadow: Double
        /// 边缘倒角宽度（会按分区大小在 0.75…1.25 倍之间调整）
        var bezel: Double
        /// 边缘最外圈往里取多远（倒角宽度的倍数）
        var bezelReach: Double
        /// 边缘受光高光强度（0…1）
        var bezelSpecular: Double
        /// 磨砂时先糊多少（点）
        var frost: Double
        /// 边缘最外圈细亮线强度 / 厚度暗带强度（液态玻璃的“厚边”）
        var rimLight: Double = 0.55
        var rimShade: Double = 0.10

        static let real = Params(ribWidth: 18, lensReach: 1.25, dispersion: 0.06, ribSpecular: 0.16, seamShadow: 0.22,
                                 bezel: 18, bezelReach: 1.0, bezelSpecular: 0.35, frost: 4)
        static let fine = Params(ribWidth: 10, lensReach: 0.85, dispersion: 0.04, ribSpecular: 0.12, seamShadow: 0.22,
                                 bezel: 22, bezelReach: 1.15, bezelSpecular: 0.30, frost: 3, rimLight: 0.75, rimShade: 0.12)
        /// 更厚的液态玻璃边（对比用）
        static let thick = Params(ribWidth: 10, lensReach: 0.85, dispersion: 0.05, ribSpecular: 0.12, seamShadow: 0.22,
                                  bezel: 30, bezelReach: 1.45, bezelSpecular: 0.38, frost: 3, rimLight: 0.9, rimShade: 0.16)
        static let wide = Params(ribWidth: 30, lensReach: 0.30, dispersion: 0.05, ribSpecular: 0.22, seamShadow: 0.38,
                                 bezel: 24, bezelReach: 1.2, bezelSpecular: 0.45, frost: 6)

        /// 正在用的一组。默认 B 细棱；TUCK_GLASS_PRESET=real / wide 只给截图对比用。
        static var current: Params {
            switch ProcessInfo.processInfo.environment["TUCK_GLASS_PRESET"] {
            case "real": return .real
            case "wide": return .wide
            case "thick": return .thick
            default: return .fine // 用户选了 B 细棱（2026-11-24）
            }
        }
    }

    /// 光的方向（屏幕平面里，指向光源；左上方来光）。
    private static let light = (x: -0.55, y: -0.83)

    /// - backdrop: 分区后面那块壁纸（像素，原点左上）；nil = 读不到壁纸，只画出棱的明暗（光栅）。
    /// - frosted: 质感是不是磨砂 / 暗色（要先糊）。
    /// - 输出：边缘模式中间透明（留给系统玻璃）；光栅模式整块不透明（没有背景时只有明暗、半透明）。
    static func render(backdrop: CGImage?, width: Int, height: Int, mode: Mode, params p: Params,
                       radius: CGFloat, scale: CGFloat, frosted: Bool) -> CGImage? {
        let w = width, h = height
        guard w >= 8, h >= 8 else { return nil }
        let bpr = w * 4
        let space = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        var src = [UInt8](repeating: 0, count: h * bpr)
        let hasBackdrop = backdrop != nil
        if let backdrop {
            guard let ctx = CGContext(data: &src, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bpr, space: space, bitmapInfo: info) else { return nil }
            ctx.draw(backdrop, in: CGRect(x: 0, y: 0, width: w, height: h))
            if frosted, p.frost > 0 { blur(&src, w: w, h: h, radius: Int((p.frost * scale).rounded())) }
        }
        // 压缩得厉害的地方（棱边、倒角最外圈）一个像素要覆盖背景里好几个像素，直接取点会出现细碎的波纹；
        // 备一张轻微模糊的背景，按压缩程度混进去（相当于 mipmap）。
        var soft = src
        if hasBackdrop { blur(&soft, w: w, h: h, radius: Int((3.5 * scale).rounded())) }
        var dst = [UInt8](repeating: 0, count: h * bpr)
        let s = Double(scale)
        let r = Double(min(radius, CGFloat(min(w, h)) / 2))
        switch mode {
        case .fluted:
            fluted(src: src, soft: soft, dst: &dst, w: w, h: h, p: p, s: s, r: r, hasBackdrop: hasBackdrop)
        case .edge:
            guard hasBackdrop else { return nil }
            edge(src: src, soft: soft, dst: &dst, w: w, h: h, p: p, s: s, r: r)
        }
        guard let provider = CGDataProvider(data: Data(dst) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bpr, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    // MARK: - 光栅（柱面透镜）

    private static func fluted(src: [UInt8], soft: [UInt8], dst: inout [UInt8], w: Int, h: Int, p: Params, s: Double, r: Double, hasBackdrop: Bool) {
        let rib = max(4, p.ribWidth * s)
        // 棱从分区中线对称排开，两边被切掉的半条棱一样宽
        let phase = (Double(w).truncatingRemainder(dividingBy: rib)) / 2
        let n = 1.5                         // 玻璃折射率
        let arc = 0.92                      // 截面用了圆的多大一段（越接近 1，棱边越陡）
        let thetaEdge = asin(arc)
        let edgeDev = tan(thetaEdge - asin(sin(thetaEdge) / n))
        let reach = p.lensReach * rib       // 棱边缘的偏移
        // 每一列：三个通道的取样横坐标 + 明暗（和行无关，只算一遍）
        var sxR = [Double](repeating: 0, count: w), sxG = sxR, sxB = sxR
        var shade = [Double](repeating: 0, count: w)   // >0 提亮，<0 压暗（-1…1）
        for x in 0..<w {
            let px = Double(x) + 0.5
            var local = (px - phase).truncatingRemainder(dividingBy: rib)
            if local < 0 { local += rib }
            let u = (local / rib) * 2 - 1                  // -1…1，棱中间为 0
            let a = u * arc
            let theta = asin(a)                            // 表面法线和视线的夹角（带符号）
            let dev = tan(abs(theta) - asin(sin(abs(theta)) / n)) / edgeDev   // 0…1 的折射偏移
            let d = (theta < 0 ? -1.0 : 1.0) * dev * reach
            // 凸面把光往棱中心折：右半边往左取，左半边往右取（够强时左右翻过来）
            sxR[x] = px - d * (1 - p.dispersion)
            sxG[x] = px - d
            sxB[x] = px - d * (1 + p.dispersion)
            // 法线（只有横向分量）：受光面亮一道窄高光；越斜反射越多（菲涅尔），透过来的略暗
            let nx = sin(theta), nz = cos(theta)
            let lz = 0.55
            let ll = (light.x * light.x + lz * lz).squareRoot()
            let ndotl = (nx * light.x + nz * lz) / ll
            let spec = pow(max(0, ndotl), 16) * p.ribSpecular
            let fresnel = pow(1 - nz, 3)
            // 棱交界处的暗线：两个圆柱面相交的“谷”，宽约 1pt
            let distToSeam = min(local, rib - local) / s
            let seam = max(0, 1 - distToSeam / 1.1)
            shade[x] = spec + fresnel * 0.06 - seam * seam * p.seamShadow - fresnel * 0.05
        }
        // 每一列的压缩程度：相邻两列取样位置差多少像素
        var mix = [Double](repeating: 0, count: w)
        for x in 0..<w {
            let a = x > 0 ? sxG[x] - sxG[x - 1] : 1, b = x < w - 1 ? sxG[x + 1] - sxG[x] : 1
            let step = max(abs(a), abs(b))
            mix[x] = abs(a - b) > 4 ? mix[max(0, x - 1)] : min(1, max(0, (step - 1.3) / 2.5)) // 棱交界处的跳变不算
        }
        let hw = Double(w) / 2, hh = Double(h) / 2
        src.withUnsafeBufferPointer { sp in
          soft.withUnsafeBufferPointer { fp in
            dst.withUnsafeMutableBufferPointer { dp in
                for y in 0..<h {
                    let py = Double(y) + 0.5
                    let row = y * w * 4
                    for x in 0..<w {
                        let cover = cornerCoverage(px: Double(x) + 0.5, py: py, hw: hw, hh: hh, r: r)
                        guard cover > 0 else { continue }
                        let o = row + x * 4
                        let k = shade[x]
                        if hasBackdrop {
                            let m = mix[x]
                            var rv = sampleRow(sp, row: row, w: w, x: sxR[x], c: 0)
                            var gv = sampleRow(sp, row: row, w: w, x: sxG[x], c: 1)
                            var bv = sampleRow(sp, row: row, w: w, x: sxB[x], c: 2)
                            if m > 0 {
                                rv += (sampleRow(fp, row: row, w: w, x: sxR[x], c: 0) - rv) * m
                                gv += (sampleRow(fp, row: row, w: w, x: sxG[x], c: 1) - gv) * m
                                bv += (sampleRow(fp, row: row, w: w, x: sxB[x], c: 2) - bv) * m
                            }
                            let a = 0.97 * cover
                            dp[o] = clamp8(light(rv, k) * a)
                            dp[o + 1] = clamp8(light(gv, k) * a)
                            dp[o + 2] = clamp8(light(bv, k) * a)
                            dp[o + 3] = clamp8(255 * a)
                        } else {
                            // 没有背景：亮处白、暗处黑，按强度给透明度（预乘）
                            let a = min(1, abs(k) * 1.1) * cover
                            let v = k > 0 ? 255 * a : 0
                            dp[o] = clamp8(v); dp[o + 1] = clamp8(v); dp[o + 2] = clamp8(v)
                            dp[o + 3] = clamp8(255 * a)
                        }
                    }
                }
            }
          }
        }
    }

    // MARK: - 边缘倒角

    private static func edge(src: [UInt8], soft: [UInt8], dst: inout [UInt8], w: Int, h: Int, p: Params, s: Double, r: Double) {
        // 倒角宽度随分区大小微调：小分区窄一点，免得边缘吃掉内容
        let minSide = Double(min(w, h)) / s
        let band = p.bezel * s * min(1.25, max(0.75, minSide / 260))
        let reach = band * p.bezelReach
        // 一维查表：从边缘往里 0…1 的位移和受光强度（超椭圆凸面 + 斯涅尔）
        let lutN = 256
        var dispLUT = [Double](repeating: 0, count: lutN + 1)
        var slopeLUT = [Double](repeating: 0, count: lutN + 1)
        let n = 1.5
        var maxDev = 1e-6
        for i in 0...lutN {
            let x = max(0.004, Double(i) / Double(lutN))      // 0 = 最外缘，1 = 倒角内侧
            // 高度 h = (1 - (1-x)^4)^(1/4)，斜率 dh/dx
            let q = 1 - x
            let base = max(1e-6, 1 - pow(q, 4))
            let slope = pow(q, 3) / pow(base, 0.75)
            let theta = atan(slope * 0.9)
            let dev = tan(theta - asin(sin(theta) / n))
            dispLUT[i] = dev; slopeLUT[i] = theta
            maxDev = max(maxDev, dev)
        }
        for i in 0...lutN { dispLUT[i] /= maxDev }
        // 压缩程度：往外走一个像素，取样点要跳多少像素
        var mixLUT = [Double](repeating: 0, count: lutN + 1)
        for i in 0...lutN {
            let i0 = max(0, i - 1), i1 = min(lutN, i + 1)
            let slope = abs(dispLUT[i1] - dispLUT[i0]) / (Double(i1 - i0) / Double(lutN)) * reach / band
            mixLUT[i] = min(1, max(0, (slope - 0.2) / 1.2))
        }
        let hw = Double(w) / 2, hh = Double(h) / 2
        let disp = p.dispersion * 1.6
        src.withUnsafeBufferPointer { sp in
          soft.withUnsafeBufferPointer { fp in
            dst.withUnsafeMutableBufferPointer { dp in
                for y in 0..<h {
                    let py = Double(y) + 0.5
                    for x in 0..<w {
                        let px = Double(x) + 0.5
                        let qx = abs(px - hw) - (hw - r), qy = abs(py - hh) - (hh - r)
                        let ox = max(qx, 0), oy = max(qy, 0)
                        let inside = -((ox * ox + oy * oy).squareRoot() + min(max(qx, qy), 0) - r)
                        guard inside > -1, inside < band else { continue }   // 外面透明；中间留给系统玻璃
                        var nx = 0.0, ny = 0.0
                        if qx > 0 && qy > 0 {
                            let l = max((qx * qx + qy * qy).squareRoot(), 1e-6)
                            nx = qx / l; ny = qy / l
                        } else if qx > qy { nx = 1 } else { ny = 1 }
                        if px < hw { nx = -nx }
                        if py < hh { ny = -ny }
                        let t = max(0, inside) / band                    // 0 边缘 … 1 内侧
                        let fi = t * Double(lutN)
                        let i0 = min(lutN - 1, Int(fi)), f = fi - Double(i0)
                        let dev = dispLUT[i0] * (1 - f) + dispLUT[i0 + 1] * f
                        let theta = slopeLUT[i0] * (1 - f) + slopeLUT[i0 + 1] * f
                        let d = dev * reach
                        let o = y * w * 4 + x * 4
                        // 色散：红的折得少、蓝的折得多
                        let m = mixLUT[i0] * (1 - f) + mixLUT[i0 + 1] * f
                        let xr = px - nx * d * (1 - disp), yr = py - ny * d * (1 - disp)
                        let xg = px - nx * d, yg = py - ny * d
                        let xb = px - nx * d * (1 + disp), yb = py - ny * d * (1 + disp)
                        var rv = sample(sp, w: w, h: h, x: xr, y: yr, c: 0)
                        var gv = sample(sp, w: w, h: h, x: xg, y: yg, c: 1)
                        var bv = sample(sp, w: w, h: h, x: xb, y: yb, c: 2)
                        if m > 0 {
                            rv += (sample(fp, w: w, h: h, x: xr, y: yr, c: 0) - rv) * m
                            gv += (sample(fp, w: w, h: h, x: xg, y: yg, c: 1) - gv) * m
                            bv += (sample(fp, w: w, h: h, x: xb, y: yb, c: 2) - bv) * m
                        }
                        // 受光：法线朝光的一侧亮，背光侧在最外缘有一点反光；越陡越亮（菲涅尔）
                        let facing = -(nx * light.x + ny * light.y)            // 朝光 = 1
                        let steep = sin(theta)
                        // 液态玻璃的“厚边”：最外缘 1.5pt 一道细亮线（朝光侧亮、背光侧弱一点的反光），
                        // 往里一点是一圈很淡的暗线（玻璃厚度的阴影），再往里是随斜率变化的柔光
                        let dpt = max(0, inside) / s                              // 离边多少点
                        let rimLine = exp(-pow((dpt - 1.0) / 0.9, 2))             // 约 1pt 处的细线
                        let innerShade = exp(-pow((dpt - 4.0) / 2.0, 2))          // 约 4pt 处的淡暗带
                        let lit = 0.55 + 0.45 * facing                            // 朝光 1，背光 0.1
                        let k = (max(0, facing) * steep * steep * p.bezelSpecular * 0.8
                                 + rimLine * p.rimLight * lit
                                 - innerShade * p.rimShade * (1.1 - lit)
                                 - (1 - t) * 0.03)
                        // 透明度：外缘实，往里渐隐到系统玻璃（smoothstep），圆角边抗锯齿
                        let fade = 1 - t
                        let alpha = (fade * fade * (3 - 2 * fade)) * 0.95 * min(1, max(0, inside + 1))
                        dp[o] = clamp8(light(rv, k) * alpha)
                        dp[o + 1] = clamp8(light(gv, k) * alpha)
                        dp[o + 2] = clamp8(light(bv, k) * alpha)
                        dp[o + 3] = clamp8(255 * alpha)
                    }
                }
            }
          }
        }
    }

    // MARK: - 小工具

    /// 圆角矩形的覆盖率（抗锯齿）：里面 1，外面 0。
    @inline(__always) private static func cornerCoverage(px: Double, py: Double, hw: Double, hh: Double, r: Double) -> Double {
        let qx = abs(px - hw) - (hw - r), qy = abs(py - hh) - (hh - r)
        guard qx > -1 || qy > -1 else { return 1 }
        let ox = max(qx, 0), oy = max(qy, 0)
        let outside = (ox * ox + oy * oy).squareRoot() + min(max(qx, qy), 0) - r
        return min(1, max(0, 0.5 - outside))
    }

    /// 提亮 / 压暗：k>0 往白推，k<0 往黑压。
    @inline(__always) private static func light(_ v: Double, _ k: Double) -> Double {
        k >= 0 ? v + (255 - v) * min(1, k) : v * (1 + max(-1, k))
    }

    @inline(__always) private static func clamp8(_ v: Double) -> UInt8 { UInt8(min(255, max(0, v))) }

    @inline(__always) private static func sampleRow(_ sp: UnsafeBufferPointer<UInt8>, row: Int, w: Int, x: Double, c: Int) -> Double {
        let fx = min(max(x - 0.5, 0), Double(w - 1))
        let x0 = Int(fx), x1 = min(x0 + 1, w - 1), a = fx - Double(x0)
        return Double(sp[row + x0 * 4 + c]) * (1 - a) + Double(sp[row + x1 * 4 + c]) * a
    }

    @inline(__always) private static func sample(_ sp: UnsafeBufferPointer<UInt8>, w: Int, h: Int, x: Double, y: Double, c: Int) -> Double {
        let fx = min(max(x - 0.5, 0), Double(w - 1)), fy = min(max(y - 0.5, 0), Double(h - 1))
        let x0 = Int(fx), y0 = Int(fy)
        let x1 = min(x0 + 1, w - 1), y1 = min(y0 + 1, h - 1)
        let ax = fx - Double(x0), ay = fy - Double(y0)
        let bpr = w * 4
        let v00 = Double(sp[y0 * bpr + x0 * 4 + c]), v10 = Double(sp[y0 * bpr + x1 * 4 + c])
        let v01 = Double(sp[y1 * bpr + x0 * 4 + c]), v11 = Double(sp[y1 * bpr + x1 * 4 + c])
        return (v00 * (1 - ax) + v10 * ax) * (1 - ay) + (v01 * (1 - ax) + v11 * ax) * ay
    }

    /// 近似高斯模糊（两次帐篷卷积），边缘按最近像素延伸，不会出现发黑的边。
    private static func blur(_ buf: inout [UInt8], w: Int, h: Int, radius: Int) {
        guard radius > 0 else { return }
        let k = UInt32(radius | 1)
        var tmp = [UInt8](repeating: 0, count: buf.count)
        buf.withUnsafeMutableBytes { bp in
            tmp.withUnsafeMutableBytes { tp in
                var a = vImage_Buffer(data: bp.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
                var b = vImage_Buffer(data: tp.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
                vImageTentConvolve_ARGB8888(&a, &b, nil, 0, 0, k, k, nil, vImage_Flags(kvImageEdgeExtend))
                vImageTentConvolve_ARGB8888(&b, &a, nil, 0, 0, k, k, nil, vImage_Flags(kvImageEdgeExtend))
            }
        }
    }
}
