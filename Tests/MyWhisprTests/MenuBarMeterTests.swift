import AppKit
import Testing
@testable import MyWhispr

@Suite("Menu bar meter")
@MainActor
struct MenuBarMeterTests {
    @Test func recordingMeterIsBlackTemplateInk() throws {
        let image = MenuBarMeter.templateImage(
            samples: Array(repeating: 1, count: 16),
            isActive: true
        )
        #expect(image.isTemplate)

        let ink = try inkPixels(of: image)
        #expect(!ink.isEmpty)
        // White ink is what disappears on a light menu bar. Template artwork is
        // black; macOS recolors it from the alpha when the bar is drawn.
        #expect(ink.allSatisfy { $0.red < 180 && $0.green < 180 && $0.blue < 180 })
        #expect(ink.contains { $0.red < 40 && $0.green < 40 && $0.blue < 40 })
    }

    @Test func louderLevelsDrawMoreInkThanSilence() throws {
        let silent = try inkPixels(of: MenuBarMeter.templateImage(
            samples: Array(repeating: 0, count: 16),
            isActive: true
        ))
        let loud = try inkPixels(of: MenuBarMeter.templateImage(
            samples: Array(repeating: 1, count: 16),
            isActive: true
        ))
        #expect(!silent.isEmpty)
        #expect(loud.count > silent.count)
    }

    private func inkPixels(of image: NSImage) throws -> [Pixel] {
        let tiff = try #require(image.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: tiff))
        var pixels: [Pixel] = []
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                var red: CGFloat = 0
                var green: CGFloat = 0
                var blue: CGFloat = 0
                var alpha: CGFloat = 0
                color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
                guard alpha > 0.4 else { continue }
                pixels.append(Pixel(
                    red: Int(red * 255),
                    green: Int(green * 255),
                    blue: Int(blue * 255)
                ))
            }
        }
        return pixels
    }

    private struct Pixel {
        var red: Int
        var green: Int
        var blue: Int
    }
}
