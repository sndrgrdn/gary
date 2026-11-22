import AppKit

setvbuf(stdout, nil, _IOLBF, 0)
let arguments = CommandLine.arguments
let seconds = arguments.count > 1 ? Double(arguments[1]) ?? 20 : 20
let interval = arguments.count > 2 ? Double(arguments[2]) ?? 0.05 : 0.05
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let panel = NSPanel(
    contentRect: NSRect(x: 100, y: 100, width: 400, height: 300), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false,
)
let content = NSView(frame: panel.contentLayoutRect)
content.wantsLayer = true
panel.contentView = content
let label = NSTextField(labelWithString: "0")
label.frame = NSRect(x: 10, y: 10, width: 300, height: 40)
content.addSubview(label)
panel.orderFrontRegardless()
let start = Date().timeIntervalSince1970
var count = 0
Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
    count += 1
    label.stringValue = "\(count)"
    content.layer?.backgroundColor = NSColor(calibratedHue: Double(count % 100) / 100, saturation: 1, brightness: 1, alpha: 1).cgColor
    content.layoutSubtreeIfNeeded()
    panel.displayIfNeeded()
    let before = Date().timeIntervalSince1970
    CATransaction.flush()
    let after = Date().timeIntervalSince1970
    print(String(format: "%.6f flush_ms=%.3f", after, (after - before) * 1000))
    if after - start > seconds {
        exit(0)
    }
}

app.run()
