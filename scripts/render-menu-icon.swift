import AppKit

// Compile alongside Sources/MenuBarIcon.swift to preview the production vector.
@main
struct IconPreview {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { return }
        let preview = NSImage(size: NSSize(width: 400, height: 120), flipped: false) { _ in
            for (x, background, foreground) in [
                (0.0, NSColor(white: 0.94, alpha: 1), NSColor.black),
                (200.0, NSColor(white: 0.12, alpha: 1), NSColor.white)
            ] {
                background.setFill()
                NSRect(x: x, y: 0, width: 200, height: 120).fill()
                let tinted = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
                    MenuBarIcon.make().draw(in: rect)
                    foreground.setFill()
                    rect.fill(using: .sourceAtop)
                    return true
                }
                tinted.draw(in: NSRect(x: x + 34, y: 33, width: 54, height: 54))
                tinted.draw(in: NSRect(x: x + 135, y: 51, width: 18, height: 18))
            }
            return true
        }
        let bitmap = NSBitmapImageRep(data: preview.tiffRepresentation!)!
        try bitmap.representation(using: .png, properties: [:])!
            .write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
    }
}
