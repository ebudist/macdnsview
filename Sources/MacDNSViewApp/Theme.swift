import AppKit
import MacDNSViewCore
import SwiftUI

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }

    static func white(_ opacity: Double) -> Color { Color.white.opacity(opacity) }

    static let t1 = white(0.88), t2 = white(0.55), t3 = white(0.32)
    static let accent = Color(hex: 0x0A84FF), accentText = Color(hex: 0x4DA3FF), accentHover = Color(hex: 0x2A94FF)
    static let ok = Color(hex: 0x30D158), warn = Color(hex: 0xFF9F0A), bad = Color(hex: 0xFF453A), problem = Color(hex: 0xFF6961)
    static let watch = Color(hex: 0xBF5AF2), amber = Color(hex: 0xFFB340)
    static let cloudflare = Color(hex: 0xF38020)
    static let window = Color(hex: 0x1E1E1E), sidebar = Color(hex: 0x282828), inspector = Color(hex: 0x1C1C1C), statusBar = Color(hex: 0x232323)
    static let sheet = Color(hex: 0x2A2A2A), popover = Color(hex: 0x2C2C2E), menu = Color(hex: 0x353537), field = Color(hex: 0x1C1C1C)
    static let code = Color(hex: 0x161616), toast = Color(hex: 0x3A3A3C), backdrop = Color(hex: 0x141416)
}

extension Font {
    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight) }
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight, design: .monospaced) }
}

extension Outcome {
    var tint: Color { switch self { case .ok: .ok; case .noData: .warn; case .failed: .bad } }
    var cellColor: Color { self == .ok ? .t1 : tint }
}

final class HoverState: ObservableObject {
    @Published var on = false
}

struct HoverButton<Label: View>: View {
    let action: () -> Void
    var normal = Color.clear
    var hover = Color.white(0.08)
    var radius: CGFloat = 5
    @ViewBuilder let label: () -> Label
    @StateObject private var state = HoverState()

    var body: some View {
        Button(action: action) { label().contentShape(Rectangle()) }
            .buttonStyle(.plain)
            .background(RoundedRectangle(cornerRadius: radius).fill(state.on ? hover : normal))
            .onHover { state.on = $0 }
    }
}

struct IconButton: View {
    let symbol: String
    var color = Color.white(0.75)
    var size: CGFloat = 13
    var width: CGFloat = 30
    var height: CGFloat = 24
    var on = false
    var onBackground = Color.white(0.1)
    let help: String
    let action: () -> Void

    var body: some View {
        HoverButton(action: action, normal: on ? onBackground : .clear) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(color)
                .frame(width: width, height: height)
        }
        .help(help)
    }
}

struct AmberButton: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        HoverButton(action: action, normal: .amber, hover: .amber.opacity(0.85), radius: 15) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                Text(title).font(.ui(13, .semibold))
            }
            .foregroundStyle(Color.black.opacity(0.85))
            .padding(.leading, 12)
            .padding(.trailing, 14)
            .frame(height: 30)
        }
    }
}

struct PrimaryButton<Label: View>: View {
    var height: CGFloat = 26
    var radius: CGFloat = 6
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        HoverButton(action: action, normal: .accent, hover: .accentHover, radius: radius) {
            label()
                .font(.ui(13, .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .frame(height: height)
        }
    }
}

struct SecondaryButton: View {
    let title: String
    var height: CGFloat = 26
    var size: CGFloat = 13
    let action: () -> Void

    var body: some View {
        HoverButton(action: action, normal: .white(0.12), hover: .white(0.16), radius: 6) {
            Text(title).font(.ui(size)).foregroundStyle(Color.white(0.9)).padding(.horizontal, 14).frame(height: height)
        }
    }
}

struct Segment: Identifiable {
    let id: String
    let label: String
    var count: String? = nil
    var help: String? = nil
    let on: Bool
    let action: () -> Void
}

struct SegmentedBar: View {
    let segments: [Segment]
    var height: CGFloat = 24
    var padding: CGFloat = 10
    var background = Color.white(0.06)

    var body: some View {
        HStack(spacing: 0) {
            ForEach(segments) { segment in
                Button(action: segment.action) {
                    HStack(spacing: 6) {
                        Text(segment.label)
                        if let count = segment.count { Text(count).font(.ui(11)).opacity(0.6).monospacedDigit() }
                    }
                    .font(.ui(12, .medium))
                    .foregroundStyle(segment.on ? Color.white : .t2)
                    .padding(.horizontal, padding)
                    .frame(maxHeight: .infinity)
                    .background(RoundedRectangle(cornerRadius: 5).fill(segment.on ? Color.white(0.16) : .clear)
                        .shadow(color: .black.opacity(segment.on ? 0.3 : 0), radius: 1, y: 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(segment.help ?? "")
            }
        }
        .padding(2)
        .frame(height: height)
        .background(RoundedRectangle(cornerRadius: 7).fill(background))
        .fixedSize()
    }
}

struct Checkbox: View {
    let label: String
    let on: Bool
    var size: CGFloat = 13
    var dot: Color? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(on ? Color.accent : .white(0.06))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(on ? Color.accent : .white(0.22)))
                    .overlay { if on { Image(systemName: "checkmark").font(.system(size: 8, weight: .heavy)).foregroundStyle(.white) } }
                    .frame(width: 14, height: 14)
                if let dot { Circle().fill(dot).frame(width: 7, height: 7) }
                Text(label).font(.ui(size)).foregroundStyle(Color.white(0.85)).multilineTextAlignment(.leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct Switch: View {
    let on: Bool

    var body: some View {
        Capsule()
            .fill(on ? Color.accent : .white(0.18))
            .frame(width: 28, height: 16)
            .overlay(alignment: on ? .trailing : .leading) { Circle().fill(.white).frame(width: 12, height: 12).padding(2) }
            .animation(.easeOut(duration: 0.15), value: on)
    }
}

struct Tag: View {
    let label: String
    let color: Color
    var background: Color? = nil

    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .bold))
            .tracking(0.4)
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5).fill(background ?? color.opacity(0.16)))
    }
}

struct Spinner: View {
    var body: some View {
        TimelineView(.animation) { context in
            Circle()
                .stroke(Color.white(0.2), lineWidth: 1.6)
                .overlay(Circle().trim(from: 0, to: 0.25).stroke(Color.accentText, lineWidth: 1.6))
                .rotationEffect(.degrees(context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.7) / 0.7 * 360))
                .frame(width: 11, height: 11)
        }
    }
}

struct Panel<Content: View>: View {
    var background = Color.popover
    var radius: CGFloat = 9
    var padding: CGFloat = 5
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .background(RoundedRectangle(cornerRadius: radius).fill(background))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(Color.white(0.12)))
            .shadow(color: .black.opacity(0.5), radius: 16, y: 12)
    }
}

struct MenuItem: View {
    let label: String
    var checked: Bool? = nil
    let action: () -> Void

    var body: some View {
        HoverButton(action: action, hover: .accent) {
            HStack(spacing: 8) {
                if let checked {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white).opacity(checked ? 1 : 0).frame(width: 12)
                }
                Text(label)
                Spacer(minLength: 0)
            }
            .font(.ui(13))
            .foregroundStyle(Color.t1)
            .padding(.horizontal, 9)
            .frame(height: 24)
        }
    }
}

extension View {
    func fieldStyle(height: CGFloat? = 26, focused: Bool = false) -> some View {
        padding(.horizontal, 9)
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.field))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(focused ? Color.accent : .white(0.12)))
    }
}

struct BrandMark: View {
    var body: some View {
        Canvas { context, size in
            let unit = size.width / 120
            func bar(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ hex: UInt32) {
                context.fill(Path(CGRect(x: x * unit, y: y * unit, width: w * unit, height: h * unit)), with: .color(Color(hex: hex)))
            }
            bar(0, 14, 120, 8, 0xF3F2F2)
            bar(0, 40, 120, 8, 0x605D5D)
            bar(0, 62, 120, 24, 0xEC3013)
            bar(0, 62, 30, 24, 0xF3F2F2)
            bar(0, 100, 120, 8, 0x605D5D)
        }
    }
}

struct WindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ChromeView() }
    func updateNSView(_ view: NSView, context: Context) {}

    final class ChromeView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.backgroundColor = NSColor(srgbRed: 0x1E / 255, green: 0x1E / 255, blue: 0x1E / 255, alpha: 1)
            if let window, window.toolbar == nil {
                // An empty unified toolbar makes the title bar 52 pt tall, which centers the window buttons in the header.
                window.toolbar = NSToolbar()
                window.toolbarStyle = .unified
                window.titleVisibility = .hidden
            }
        }
    }
}
