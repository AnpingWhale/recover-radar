import AppKit
import SwiftUI
import RecoveryCore
import RecoveryUI

@main
struct RenderWidgetPreviews {
    @MainActor static func main() throws {
        let snapshot = DemoFixtures.snapshot()
        for dark in [false, true] {
            // Liquid Glass needs a live window/compositor. Export opaque layout
            // references; inspect real glass in the running preview gallery.
            let renderer = ImageRenderer(content: WidgetDesktopPreview(snapshot: snapshot, darkAppearance: dark, usesNativeGlass: false))
            renderer.scale = 2
            guard let image = renderer.cgImage,
                  let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let name = dark ? "dark" : "light"
            try data.write(to: URL(fileURLWithPath: "build/widget-preview-\(name).png"))
        }
    }
}
