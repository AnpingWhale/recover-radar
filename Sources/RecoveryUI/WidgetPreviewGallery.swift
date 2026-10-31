import SwiftUI
import Combine
import RecoveryCore

@MainActor
private final class WidgetPreviewAppearance: ObservableObject {
    @Published var isDark = true
}

/// A visual preview, not a substitute for WidgetKit registration or desktop installation.
public struct WidgetPreviewGallery: View {
    @StateObject private var appearance = WidgetPreviewAppearance()
    private let snapshot: RadarSnapshot

    public init(snapshot: RadarSnapshot = DemoFixtures.snapshot()) {
        self.snapshot = snapshot
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("桌面小组件").font(.system(size: 26, weight: .semibold))
                    Text("Liquid Glass · 当天状态与近 30 天基线")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("背景", selection: $appearance.isDark) {
                    Text("浅色").tag(false)
                    Text("深色").tag(true)
                }
                .pickerStyle(.segmented).frame(width: 150)
            }

            WidgetDesktopPreview(snapshot: snapshot, darkAppearance: appearance.isDark)
                .clipShape(RoundedRectangle(cornerRadius: 22))

            HStack {
                Label("视觉预览 · 合成演示数据", systemImage: "eye")
                Spacer()
                Text("桌面透明样式由系统提供，随壁纸与着色变化")
            }
            .font(.caption).foregroundStyle(.secondary)
            Text("当前展示中号和大号布局；安装到桌面仍需完成应用签名与小组件安装。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(32)
        .frame(width: 920)
    }
}

/// Uses the same view as the extension, with reference-size desktop frames for review.
public struct WidgetDesktopPreview: View {
    public let snapshot: RadarSnapshot
    public let darkAppearance: Bool
    /// ImageRenderer cannot capture the system glass compositor. Static exports
    /// deliberately use an opaque surface and only validate the shared layout.
    public let usesNativeGlass: Bool

    public init(snapshot: RadarSnapshot, darkAppearance: Bool = false, usesNativeGlass: Bool = true) {
        self.snapshot = snapshot
        self.darkAppearance = darkAppearance
        self.usesNativeGlass = usesNativeGlass
    }

    public var body: some View {
        glassCards
        .padding(32)
        .frame(width: 856, height: 468, alignment: .top)
        .background { PreviewWallpaper(isDark: darkAppearance) }
        .environment(\.colorScheme, darkAppearance ? .dark : .light)
    }

    @ViewBuilder private var glassCards: some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *), usesNativeGlass {
            // Less than the 36 pt card gap: the surfaces must remain separate.
            GlassEffectContainer(spacing: 20) { cards }
        } else {
            cards
        }
        #else
        cards
        #endif
    }

    private var cards: some View {
        HStack(alignment: .top, spacing: 36) {
            card(.medium)
            card(.large)
        }
    }

    private func card(_ size: RecoveryWidgetSize) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(size.title).font(.caption.weight(.medium)).foregroundStyle(.white.opacity(0.85))
            RecoveryWidgetContent(snapshot: snapshot, size: size, now: snapshot.generatedAt, monochrome: true)
                .padding(12)
                .frame(width: size.previewWidth, height: size.previewHeight)
                .modifier(WidgetGlassSurface(usesNativeGlass: usesNativeGlass))
                // macOS Clear widgets tint both content groups white, including
                // on a light desktop. Keep the preview consistent with that mode.
                .environment(\.colorScheme, .dark)
        }
    }
}

/// App-only shell. The actual extension delegates this surface to WidgetKit.
private struct WidgetGlassSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme
    let usesNativeGlass: Bool
    private let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)

    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency || contrast == .increased || !usesNativeGlass {
            content
                .background(colorScheme == .dark ? Color(red: 0.10, green: 0.15, blue: 0.20) : Color(red: 0.94, green: 0.96, blue: 0.98), in: shape)
                .overlay(shape.strokeBorder(Color.primary.opacity(contrast == .increased ? 0.6 : 0.15), lineWidth: 1))
        } else {
            nativeSurface(content)
        }
    }

    @ViewBuilder private func nativeSurface(_ content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            content
                // Our controlled wallpaper needs a small dark scrim for dense
                // white labels; the native clear material supplies the optics.
                .background(.black.opacity(0.16), in: shape)
                .glassEffect(.clear, in: shape)
        } else {
            materialSurface(content)
        }
        #else
        materialSurface(content)
        #endif
    }

    private func materialSurface(_ content: Content) -> some View {
        content.background(.regularMaterial, in: shape)
            .overlay(shape.strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
    }
}

/// An original, static wallpaper gives the native material light and contours to
/// refract without images, network access, animation, or third-party assets.
private struct PreviewWallpaper: View {
    let isDark: Bool

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                LinearGradient(colors: isDark
                               ? [Color(red: 0.06, green: 0.12, blue: 0.26), Color(red: 0.08, green: 0.36, blue: 0.42)]
                               : [Color(red: 0.18, green: 0.39, blue: 0.64), Color(red: 0.32, green: 0.68, blue: 0.73)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Ellipse()
                    .fill(LinearGradient(colors: [.cyan.opacity(isDark ? 0.28 : 0.5), .blue.opacity(0.02)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: geometry.size.width * 1.25, height: geometry.size.height * 1.4)
                    .rotationEffect(.degrees(-32))
                    .offset(x: 130, y: 240)
                    .blur(radius: 2)
                Ellipse()
                    .stroke(LinearGradient(colors: [.white.opacity(0.4), .cyan.opacity(0.05)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 3)
                    .frame(width: geometry.size.width * 1.25, height: geometry.size.height * 1.4)
                    .rotationEffect(.degrees(-32))
                    .offset(x: 130, y: 240)
                    .blur(radius: 3)
            }
            .clipped()
        }
        .accessibilityHidden(true)
    }
}
