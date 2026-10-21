// Helper for scripts/make-icon.sh and scripts/check-icon-render.sh. It inspects and
// normalizes the app icon artwork (design/icon.png), and checks the icon that the system
// renders for a built app against that artwork.
//
// Usage:
//   icon-tool stats <artwork.png>
//       Alpha inside the artwork's interior: the base region reached from the centre through
//       pixels with alpha >= 128, eroded by 3 px so that the anti-aliased rim is left out.
//   icon-tool check <artwork.png>
//       Exits 1 unless every interior pixel is fully opaque (alpha 255).
//   icon-tool normalize <in.png> <out.png> [threshold]
//       Sets the alpha of every pixel with alpha >= threshold (default 240) to 255. Colour
//       channels are straight (unpremultiplied) and are not touched, so colours are preserved;
//       every other pixel is left as it was.
//   icon-tool render <app> <outdir> <size>...
//       Writes the icon that NSWorkspace returns for the bundle, drawn at each size, to
//       <outdir>/icon-<size>.png.
//   icon-tool compare <artwork.png> <render.png>
//       Compares the render with the artwork itself, so the check does not depend on the
//       artwork's design: no colours, panes or regions are named. Exits 1 when a square of
//       render pixels differs from the artwork. See "Comparison with the artwork". At 32 px
//       the comparison is a smoke check, not a detector (see scripts/check-icon-render.sh).

import AppKit
import CoreGraphics
import Foundation
import ImageIO

struct Image {
    let width: Int
    let height: Int
    var pixels: [UInt8]  // straight RGBA, 4 bytes per pixel, row by row
    let colorSpace: CGColorSpace

    func alpha(_ x: Int, _ y: Int) -> UInt8 { pixels[(y * width + x) * 4 + 3] }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func load(_ path: String) -> Image {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { fail("\(path): cannot be read as an image") }
    // Only 8-bit straight RGBA in the byte order of the PNG is read directly, so that the colour
    // channels are exactly the ones stored in the file.
    guard image.bitsPerComponent == 8, image.bitsPerPixel == 32, image.alphaInfo == .last,
          image.bitmapInfo.rawValue & CGBitmapInfo.byteOrderMask.rawValue == 0,
          let provider = image.dataProvider, let data = provider.data
    else { fail("\(path): expected an 8-bit straight RGBA image") }
    let bytes = CFDataGetBytePtr(data)!
    let rowBytes = image.bytesPerRow
    let width = image.width, height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    for y in 0..<height {
        for i in 0..<(width * 4) {
            pixels[y * width * 4 + i] = bytes[y * rowBytes + i]
        }
    }
    return Image(width: width, height: height, pixels: pixels,
                 colorSpace: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!)
}

func save(_ image: Image, to path: String) {
    guard let provider = CGDataProvider(data: Data(image.pixels) as CFData),
          let cgImage = CGImage(width: image.width, height: image.height, bitsPerComponent: 8,
                                bitsPerPixel: 32, bytesPerRow: image.width * 4,
                                space: image.colorSpace,
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                provider: provider, decode: nil, shouldInterpolate: false,
                                intent: .defaultIntent),
          let destination = CGImageDestinationCreateWithURL(
              URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil)
    else { fail("cannot write \(path)") }
    CGImageDestinationAddImage(destination, cgImage, nil)
    guard CGImageDestinationFinalize(destination) else { fail("cannot write \(path)") }
}

// MARK: - Grids

// The base of an icon image: the pixels reached from the centre through alpha >= 128.
func baseRegion(_ image: Image, _ what: String) -> [Bool] {
    let w = image.width, h = image.height
    guard image.alpha(w / 2, h / 2) >= 128 else { fail("the centre of \(what) is not opaque") }
    var base = [Bool](repeating: false, count: w * h)
    let seed = (h / 2) * w + w / 2
    base[seed] = true
    var queue = [seed]
    var head = 0
    while head < queue.count {
        let p = queue[head]
        head += 1
        let x = p % w, y = p / w
        let neighbours = [(x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)]
        for (nx, ny) in neighbours where nx >= 0 && nx < w && ny >= 0 && ny < h {
            let q = ny * w + nx
            if !base[q] && image.pixels[q * 4 + 3] >= 128 {
                base[q] = true
                queue.append(q)
            }
        }
    }
    return base
}

// Inclusive bounds of the true pixels of a grid, or nil when there are none.
func bounds(_ mask: [Bool], width w: Int, height h: Int) -> (x0: Int, y0: Int, x1: Int, y1: Int)? {
    var b = (x0: w, y0: h, x1: -1, y1: -1)
    for y in 0..<h {
        for x in 0..<w where mask[y * w + x] {
            b.x0 = min(b.x0, x); b.x1 = max(b.x1, x)
            b.y0 = min(b.y0, y); b.y1 = max(b.y1, y)
        }
    }
    return b.x1 < 0 ? nil : b
}

// True where a pixel and every pixel of the square of the given radius around it are true.
// Pixels outside the grid count as false.
func erode(_ mask: [Bool], width w: Int, height h: Int, radius r: Int) -> [Bool] {
    var out = [Bool](repeating: false, count: w * h)
    for y in 0..<h {
        for x in 0..<w where mask[y * w + x] {
            var all = true
            for ny in (y - r)...(y + r) where all {
                for nx in (x - r)...(x + r) where all {
                    all = nx >= 0 && ny >= 0 && nx < w && ny < h && mask[ny * w + nx]
                }
            }
            out[y * w + x] = all
        }
    }
    return out
}

// True at the top-left corner of every square of the given side whose pixels are all true.
func squares(_ mask: [Bool], width w: Int, height h: Int, side s: Int) -> [Bool] {
    var out = [Bool](repeating: false, count: w * h)
    guard s <= w, s <= h else { return out }
    for y in 0...(h - s) {
        for x in 0...(w - s) {
            var all = true
            for dy in 0..<s where all {
                for dx in 0..<s where all {
                    all = mask[(y + dy) * w + x + dx]
                }
            }
            out[y * w + x] = all
        }
    }
    return out
}

// Summed-area table of value over a w x h grid; rectSum reads the sum over any rectangle.
func summedArea(width w: Int, height h: Int, _ value: (Int) -> Int) -> [Int] {
    var sums = [Int](repeating: 0, count: (w + 1) * (h + 1))
    for y in 0..<h {
        var rowSum = 0
        for x in 0..<w {
            rowSum += value(y * w + x)
            sums[(y + 1) * (w + 1) + (x + 1)] = sums[y * (w + 1) + (x + 1)] + rowSum
        }
    }
    return sums
}

// The sum over the pixels x0 ..< x1 and y0 ..< y1 of a table made by summedArea.
func rectSum(_ sums: [Int], width w: Int, _ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> Int {
    sums[y1 * (w + 1) + x1] - sums[y0 * (w + 1) + x1] - sums[y1 * (w + 1) + x0] + sums[y0 * (w + 1) + x0]
}

// MARK: - Interior

struct Masks {
    var base: [Bool]      // reached from the centre through alpha >= 128
    var interior: [Bool]  // base pixels whose 7x7 neighbourhood is all base
}

func masks(_ image: Image) -> Masks {
    let w = image.width, h = image.height
    let base = baseRegion(image, "the artwork")
    let sums = summedArea(width: w, height: h) { base[$0] ? 1 : 0 }
    let r = 3
    let full = (2 * r + 1) * (2 * r + 1)
    var interior = [Bool](repeating: false, count: w * h)
    for y in r..<(h - r) {
        for x in r..<(w - r) where base[y * w + x] {
            let s = rectSum(sums, width: w, x - r, y - r, x + r + 1, y + r + 1)
            if s == full { interior[y * w + x] = true }
        }
    }
    return Masks(base: base, interior: interior)
}

func stats(_ path: String) {
    let image = load(path)
    let m = masks(image)
    let w = image.width, h = image.height
    var histogram = [Int](repeating: 0, count: 256)
    var interiorCount = 0
    var lowest: (alpha: UInt8, x: Int, y: Int) = (255, 0, 0)
    var blockMin = [[Int]](repeating: [Int](repeating: -1, count: 16), count: 16)
    for y in 0..<h {
        for x in 0..<w where m.interior[y * w + x] {
            let a = image.alpha(x, y)
            interiorCount += 1
            histogram[Int(a)] += 1
            if a < lowest.alpha { lowest = (a, x, y) }
            let bx = min(x * 16 / w, 15), by = min(y * 16 / h, 15)
            if blockMin[by][bx] < 0 || Int(a) < blockMin[by][bx] { blockMin[by][bx] = Int(a) }
        }
    }
    let base = m.base.reduce(0) { $0 + ($1 ? 1 : 0) }
    print("base region: \(base) px, interior (rim removed): \(interiorCount) px")
    let notOpaque = interiorCount - histogram[255]
    print("interior pixels with alpha below 255: \(notOpaque)")
    print("interior pixels with alpha below 240: \(histogram[0..<240].reduce(0, +))")
    print("lowest interior alpha: \(lowest.alpha) at x=\(lowest.x) y=\(lowest.y)")
    print("interior alpha histogram (alpha: count):")
    var line = ""
    for a in stride(from: 255, through: 0, by: -1) where histogram[a] > 0 {
        line += "\(a): \(histogram[a])  "
    }
    print(line)
    print("minimum interior alpha per 1/16 block (rows top to bottom, '.' = no interior):")
    for row in blockMin {
        print(row.map { $0 < 0 ? "  ." : String(format: "%3d", $0) }.joined(separator: " "))
    }
}

func check(_ path: String) {
    let image = load(path)
    let m = masks(image)
    var notOpaque = 0
    var lowest: (alpha: UInt8, x: Int, y: Int) = (255, 0, 0)
    for y in 0..<image.height {
        for x in 0..<image.width where m.interior[y * image.width + x] {
            let a = image.alpha(x, y)
            if a < 255 {
                notOpaque += 1
                if a < lowest.alpha { lowest = (a, x, y) }
            }
        }
    }
    guard notOpaque == 0 else {
        var hint = "Run scripts/make-icon.sh --normalize to set every interior alpha of 240 or more to 255."
        if lowest.alpha < 240 {
            hint = "Pixels below alpha 240 are not normalized automatically; look at the artwork first."
        }
        fail("""
            \(path): the interior is not fully opaque: \(notOpaque) pixels below alpha 255, \
            the lowest is \(lowest.alpha) at x=\(lowest.x) y=\(lowest.y). macOS draws such an \
            icon with blotches (scripts/check-icon-render.sh shows them). \(hint)
            """)
    }
    print("interior fully opaque")
}

func normalize(_ input: String, _ output: String, threshold: UInt8) {
    var image = load(input)
    let original = image
    let m = masks(image)
    var changed = 0, changedInside = 0
    for p in 0..<(image.width * image.height) {
        let a = image.pixels[p * 4 + 3]
        if a >= threshold && a != 255 {
            image.pixels[p * 4 + 3] = 255
            changed += 1
            if m.interior[p] { changedInside += 1 }
        }
    }
    save(image, to: output)

    // Verify the written file: colour channels and every unchanged alpha are identical.
    let written = load(output)
    guard written.width == original.width, written.height == original.height else {
        fail("the written file has another size")
    }
    var colourDifferences = 0, alphaDifferences = 0
    for p in 0..<(original.width * original.height) {
        for c in 0..<3 where written.pixels[p * 4 + c] != original.pixels[p * 4 + c] {
            colourDifferences += 1
        }
        let a = original.pixels[p * 4 + 3]
        let expected: UInt8 = a >= threshold ? 255 : a
        if written.pixels[p * 4 + 3] != expected { alphaDifferences += 1 }
    }
    guard colourDifferences == 0, alphaDifferences == 0 else {
        fail("verification failed: \(colourDifferences) colour and \(alphaDifferences) alpha values differ")
    }
    print("alpha set to 255 on \(changed) pixels (\(changedInside) inside the interior, threshold \(threshold))")
    print("verified: colour channels identical everywhere, all other alpha values unchanged")
}

// MARK: - Rendering

func render(app: String, outDirectory: String, sizes: [Int]) {
    let icon = NSWorkspace.shared.icon(forFile: app)
    for size in sizes {
        guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 32),
              let context = NSGraphicsContext(bitmapImageRep: rep),
              let png = {
                  NSGraphicsContext.saveGraphicsState()
                  NSGraphicsContext.current = context
                  context.cgContext.clear(CGRect(x: 0, y: 0, width: size, height: size))
                  icon.draw(in: NSRect(x: 0, y: 0, width: size, height: size), from: .zero,
                            operation: .sourceOver, fraction: 1)
                  NSGraphicsContext.restoreGraphicsState()
                  return rep.representation(using: .png, properties: [:])
              }()
        else { fail("cannot render the icon at \(size) px") }
        let path = (outDirectory as NSString).appendingPathComponent("icon-\(size).png")
        do {
            try png.write(to: URL(fileURLWithPath: path))
        } catch {
            fail("cannot write \(path): \(error.localizedDescription)")
        }
        print("rendered \(size)x\(size) to \(path)")
    }
}

// MARK: - Comparison with the artwork

// The artwork is scaled into the base box of the render, and the two are compared pixel by
// pixel. Nothing about the artwork's design is assumed: no colour, pane or region is named.
//
// The method, with the constants below:
// 1. The base of each image is the region reached from its centre through alpha >= 128. The
//    artwork's base box is mapped onto the render's base box, one cell per render pixel. A cell
//    is the mean colour of the artwork's base pixels under it, and it is full when all of them
//    are base pixels.
// 2. A cell is sound when it is full, no full neighbour differs from it by more than
//    compareEdgeStep in any channel, and no pixel within the margin of it is unsound. The margin
//    is the mapping's error plus the blur of the system's resampling: the system clips the base
//    by its own icon mask (a pixel or two at the sides at 256 px), and it blurs colour edges.
// 3. A sound cell is compared with the render pixel: a difference is the Euclidean distance of
//    the colours over R, G and B (0 to 441), or the distance of the alpha from 255, whichever is
//    larger. A cell differs when the difference exceeds compareDifference.
// 4. A difference is reported only when it fills a square of reportedSquareSide render pixels,
//    so that an edge or a single pixel never fails the check.
//
// Constants, in render pixels unless stated:
let compareEdgeStep = 12.0    // colour step between neighbouring cells that counts as an edge (0-255)
let compareDifference = 48.0  // a difference above this (Euclidean over RGB, or alpha from 255)

// The margin between a compared cell and the base rim or a colour edge: 2 px for a base 206 px
// wide (256 px icon), 1 px for a base 26 px wide (32 px icon).
func comparisonMargin(baseWidth w: Int) -> Int { max(1, w / 100) }

// The side of the squares of differing pixels that are reported: 5 px for a base 206 px wide,
// 2 px for a base 26 px wide.
func reportedSquareSide(baseWidth w: Int) -> Int { max(2, w / 40) }

typealias Colour = (r: Double, g: Double, b: Double)

// The pixels [start, end) of an artwork axis that cell i of n covers, when the base box starts
// at start and is length pixels long.
func footprint(_ i: Int, start: Int, length: Int, cells n: Int) -> (Int, Int) {
    let a = start + i * length / n
    return (a, max(start + (i + 1) * length / n, a + 1))
}

func compare(artwork: String, rendered: String) {
    let art = load(artwork)
    let ren = load(rendered)
    let artBase = baseRegion(art, "the artwork")
    let renBase = baseRegion(ren, "the render")
    guard let ab = bounds(artBase, width: art.width, height: art.height),
          let rb = bounds(renBase, width: ren.width, height: ren.height)
    else { fail("cannot find the base in the artwork or the render") }
    let aw = ab.x1 - ab.x0 + 1, ah = ab.y1 - ab.y0 + 1  // the base box in the artwork
    let cw = rb.x1 - rb.x0 + 1, ch = rb.y1 - rb.y0 + 1  // the base box in the render

    // Step 1: the artwork scaled into the render's base box.
    let aW = art.width, aH = art.height
    let count = summedArea(width: aW, height: aH) { artBase[$0] ? 1 : 0 }
    let reds = summedArea(width: aW, height: aH) { artBase[$0] ? Int(art.pixels[$0 * 4]) : 0 }
    let greens = summedArea(width: aW, height: aH) { artBase[$0] ? Int(art.pixels[$0 * 4 + 1]) : 0 }
    let blues = summedArea(width: aW, height: aH) { artBase[$0] ? Int(art.pixels[$0 * 4 + 2]) : 0 }
    var expected = [Colour](repeating: (0, 0, 0), count: cw * ch)
    var full = [Bool](repeating: false, count: cw * ch)
    for j in 0..<ch {
        let (y0, y1) = footprint(j, start: ab.y0, length: ah, cells: ch)
        for i in 0..<cw {
            let (x0, x1) = footprint(i, start: ab.x0, length: aw, cells: cw)
            let n = rectSum(count, width: aW, x0, y0, x1, y1)
            guard n > 0 else { continue }
            let k = j * cw + i
            full[k] = n == (x1 - x0) * (y1 - y0)
            let d = Double(n)
            expected[k] = (Double(rectSum(reds, width: aW, x0, y0, x1, y1)) / d,
                           Double(rectSum(greens, width: aW, x0, y0, x1, y1)) / d,
                           Double(rectSum(blues, width: aW, x0, y0, x1, y1)) / d)
        }
    }

    // Step 2: the sound cells, and the compared ones (sound, with a margin).
    var sound = [Bool](repeating: false, count: cw * ch)
    for j in 0..<ch {
        for i in 0..<cw where full[j * cw + i] {
            let a = expected[j * cw + i]
            var edge = false
            for dy in -1...1 {
                for dx in -1...1 where !edge {
                    let x = i + dx, y = j + dy
                    guard x >= 0, y >= 0, x < cw, y < ch, full[y * cw + x] else { continue }
                    let b = expected[y * cw + x]
                    edge = max(abs(a.r - b.r), abs(a.g - b.g), abs(a.b - b.b)) > compareEdgeStep
                }
            }
            sound[j * cw + i] = !edge
        }
    }
    let margin = comparisonMargin(baseWidth: cw)
    let compared = erode(sound, width: cw, height: ch, radius: margin)

    // Step 3: the differences of the compared cells.
    var differs = [Bool](repeating: false, count: cw * ch)
    var deviation = [Double](repeating: 0, count: cw * ch)
    var comparedCount = 0, differingCount = 0, largest = 0.0
    for j in 0..<ch {
        for i in 0..<cw where compared[j * cw + i] {
            let k = j * cw + i
            let p = ((rb.y0 + j) * ren.width + rb.x0 + i) * 4
            let e = expected[k]
            let dr = Double(ren.pixels[p]) - e.r
            let dg = Double(ren.pixels[p + 1]) - e.g
            let db = Double(ren.pixels[p + 2]) - e.b
            let d = max((dr * dr + dg * dg + db * db).squareRoot(), abs(Double(ren.pixels[p + 3]) - 255))
            comparedCount += 1
            deviation[k] = d
            largest = max(largest, d)
            if d > compareDifference {
                differs[k] = true
                differingCount += 1
            }
        }
    }

    // Step 4: a difference is reported only when it fills a square.
    let side = reportedSquareSide(baseWidth: cw)
    let tops = squares(differs, width: cw, height: ch, side: side)
    let squareCount = tops.reduce(0) { $0 + ($1 ? 1 : 0) }
    print("render base x \(rb.x0)-\(rb.x1) y \(rb.y0)-\(rb.y1), artwork base x \(ab.x0)-\(ab.x1) y \(ab.y0)-\(ab.y1)")
    print("compared \(comparedCount) render pixels, margin \(margin) px from the base rim and colour edges")
    print("largest difference \(String(format: "%.1f", largest)), pixels above \(Int(compareDifference)): \(differingCount), "
          + "squares of \(side) x \(side) px that differ: \(squareCount)")
    guard let region = bounds(tops, width: cw, height: ch) else {
        print("verdict: the render matches the artwork")
        return
    }

    // The region of the squares, in render and artwork pixels, and its most different pixel.
    let i0 = region.x0, i1 = region.x1 + side - 1
    let j0 = region.y0, j1 = region.y1 + side - 1
    var worst = (i: i0, j: j0, d: -1.0)
    for j in j0...j1 {
        for i in i0...i1 where differs[j * cw + i] && deviation[j * cw + i] > worst.d {
            worst = (i, j, deviation[j * cw + i])
        }
    }
    let artX0 = footprint(i0, start: ab.x0, length: aw, cells: cw).0
    let artX1 = footprint(i1, start: ab.x0, length: aw, cells: cw).1 - 1
    let artY0 = footprint(j0, start: ab.y0, length: ah, cells: ch).0
    let artY1 = footprint(j1, start: ab.y0, length: ah, cells: ch).1 - 1
    let p = ((rb.y0 + worst.j) * ren.width + rb.x0 + worst.i) * 4
    let e = expected[worst.j * cw + worst.i]
    print("verdict: the render differs from the artwork in \(squareCount) square(s) of \(side) x \(side) render pixels")
    print("  at render x \(rb.x0 + i0)-\(rb.x0 + i1) y \(rb.y0 + j0)-\(rb.y0 + j1), artwork x \(artX0)-\(artX1) y \(artY0)-\(artY1)")
    print("  most different pixel, render (\(rb.x0 + worst.i), \(rb.y0 + worst.j)): rendered (\(ren.pixels[p]), \(ren.pixels[p + 1]), \(ren.pixels[p + 2]), alpha \(ren.pixels[p + 3])), artwork (\(Int(e.r.rounded())), \(Int(e.g.rounded())), \(Int(e.b.rounded())))")
    exit(1)
}

// MARK: - Command line

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    fail("usage: icon-tool stats|check <artwork.png> | normalize <in.png> <out.png> [threshold] | render <app> <outdir> <size>... | compare <artwork.png> <render.png>")
}
switch arguments[1] {
case "stats":
    stats(arguments[2])
case "check":
    check(arguments[2])
case "normalize":
    guard arguments.count >= 4 else { fail("usage: icon-tool normalize <in.png> <out.png> [threshold]") }
    let threshold = arguments.count >= 5 ? UInt8(arguments[4]) ?? 240 : 240
    normalize(arguments[2], arguments[3], threshold: threshold)
case "render":
    guard arguments.count >= 5 else { fail("usage: icon-tool render <app> <outdir> <size>...") }
    let sizes = arguments[4...].map { Int($0) ?? 0 }
    guard sizes.allSatisfy({ $0 > 0 }) else { fail("sizes must be positive integers") }
    render(app: arguments[2], outDirectory: arguments[3], sizes: sizes)
case "compare":
    guard arguments.count >= 4 else { fail("usage: icon-tool compare <artwork.png> <render.png>") }
    compare(artwork: arguments[2], rendered: arguments[3])
default:
    fail("unknown command \(arguments[1])")
}
