import AppKit

/// Verifies the ghost-text colour actually inverts with the background. This is
/// the fix for a real defect: 42% black is invisible on a dark field.

func image(red: Double, green: Double, blue: Double) -> CGImage {
    let width = 32, height = 8
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()!
}

struct Case {
    let name: String
    let rgb: (Double, Double, Double)
    let expectDark: Bool
}

let cases = [
    Case(name: "white page",     rgb: (1.0, 1.0, 1.0), expectDark: false),
    Case(name: "near-white",     rgb: (0.95, 0.95, 0.93), expectDark: false),
    Case(name: "black terminal", rgb: (0.0, 0.0, 0.0), expectDark: true),
    Case(name: "dark editor",    rgb: (0.12, 0.12, 0.14), expectDark: true),
    Case(name: "solarized dark", rgb: (0.0, 0.17, 0.21), expectDark: true),
    // Green is heavily weighted in Rec.709 luma, so this must read as light.
    Case(name: "bright green",   rgb: (0.2, 0.9, 0.2), expectDark: false),
]

var failures = 0
for test in cases {
    let frame = CapturedFrame(
        image: image(red: test.rgb.0, green: test.rgb.1, blue: test.rgb.2),
        rect: .zero
    )
    guard let backdrop = BackdropSampler.sample(frame) else {
        print("FAIL \(test.name): sampler returned nil"); failures += 1; continue
    }
    let ok = backdrop.isDark == test.expectDark
    if !ok { failures += 1 }
    let ghost = backdrop.ghostColor.usingColorSpace(.deviceRGB)!
    print(String(format: "%@ %-16s luma %.2f  isDark %@  ghost white %.2f @ %.0f%%",
                 ok ? "PASS" : "FAIL",
                 (test.name as NSString).utf8String!,
                 backdrop.luminance,
                 backdrop.isDark ? "yes" : "no ",
                 ghost.redComponent, ghost.alphaComponent * 100))
}

// A dark backdrop must yield a light ghost and vice versa, or the fix is a no-op.
let dark = BackdropSampler.sample(CapturedFrame(image: image(red: 0, green: 0, blue: 0), rect: .zero))!
let light = BackdropSampler.sample(CapturedFrame(image: image(red: 1, green: 1, blue: 1), rect: .zero))!
let darkGhost = dark.ghostColor.usingColorSpace(.deviceRGB)!.redComponent
let lightGhost = light.ghostColor.usingColorSpace(.deviceRGB)!.redComponent
if darkGhost <= lightGhost {
    print("FAIL contrast inversion: dark bg ghost \(darkGhost) should exceed light bg ghost \(lightGhost)")
    failures += 1
} else {
    print("PASS contrast inverts with background")
}

print(failures == 0 ? "\nAll \(cases.count + 1) backdrop cases passed." : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
