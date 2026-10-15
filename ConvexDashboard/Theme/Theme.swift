import CoreText
import SwiftUI
import UIKit

// Visual language borrowed from convex.dev: warm off-white surfaces, near-black text, and the
// brand red / yellow / plum used sparingly as accents. Hex values come from the site's CSS
// variables (--color-seashell, --color-plum-p4, --color-red-r3, ...).
// Fonts: Kanit (Convex's logotype font) for display text, IBM Plex Mono (the site's mono font)
// for numbers, identifiers, and labels. Both are SIL OFL and bundled in Resources/Fonts.
// Body text stays on the system font (the site's GT America is a commercial font).

// MARK: - Colors

extension Color {
    // Dark mode leans on Convex's warm browns (raisin, cocoa) rather than neutral grays.
    /// Screen background. seashell / warm near-black
    static let convexBackground = Color(light: 0xF9F7EE, dark: 0x171413)
    /// Cards and list rows. milk / raisin
    static let convexSurface = Color(light: 0xFFFDF4, dark: 0x262321)
    /// Hairlines and subtle fills. eggshell / warm charcoal
    static let convexHairline = Color(light: 0xF3ECDB, dark: 0x3A3532)
    /// raisin / alabaster
    static let convexText = Color(light: 0x262321, dark: 0xF6F3E5)
    static let convexSecondaryText = Color(light: 0x6D6D70, dark: 0xA8A29A)

    /// App tint. plum-p4, and orchid in dark mode for contrast on brown-black.
    static let convexAccent = Color(light: 0x8D2676, dark: 0xE79CD6)
    /// Filled controls (toggles, prominent buttons): plum stays saturated in dark mode,
    /// where the text accent (orchid) would look washed out behind a white knob.
    static let convexAccentFill = Color(light: 0x8D2676, dark: 0xA8358F)
    static let convexRed = Color(light: 0xD62F2A, dark: 0xF15D59)
    /// Yellow is too light for text on cream, so light mode uses tikkaMasala.
    static let convexYellow = Color(light: 0xBC7914, dark: 0xF3B01C)
    static let convexGreen = Color(light: 0x479E12, dark: 0x72C043)
    static let convexBlue = Color(light: 0x3D72F5, dark: 0x91AEF7)
    static let convexAero = Color(light: 0x2E8DB5, dark: 0x69BEE2)

    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

private extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

// MARK: - Fonts

enum ConvexFont {
    static let displayMedium = "Kanit-Medium"
    static let displaySemibold = "Kanit-SemiBold"
    static let monoRegular = "IBMPlexMono-Regular"
    static let monoMedium = "IBMPlexMono-Medium"
    static let monoSemibold = "IBMPlexMono-SemiBold"

    /// Registers bundled fonts for this process (no Info.plist `UIAppFonts` needed).
    static func register() {
        let urls = Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? []
        CTFontManagerRegisterFontURLs(urls as CFArray, .process, true, nil)
    }

    /// Default point sizes per text style, so custom fonts scale with Dynamic Type.
    fileprivate static func size(for style: Font.TextStyle) -> CGFloat {
        switch style {
        case .largeTitle: 34
        case .title: 28
        case .title2: 22
        case .title3: 20
        case .headline, .body: 17
        case .callout: 16
        case .subheadline: 15
        case .footnote: 13
        case .caption: 12
        case .caption2: 11
        @unknown default: 17
        }
    }
}

extension Font {
    /// Kanit, for titles and hero numbers.
    static func convexDisplay(_ style: Font.TextStyle = .title, weight: Font.Weight = .semibold) -> Font {
        let name = weight == .medium ? ConvexFont.displayMedium : ConvexFont.displaySemibold
        return .custom(name, size: ConvexFont.size(for: style), relativeTo: style)
    }

    /// IBM Plex Mono, for metrics, function paths, logs, and eyebrow labels.
    static func convexMono(_ style: Font.TextStyle = .body, weight: Font.Weight = .regular) -> Font {
        let name = switch weight {
        case .semibold, .bold, .heavy, .black: ConvexFont.monoSemibold
        case .medium: ConvexFont.monoMedium
        default: ConvexFont.monoRegular
        }
        return .custom(name, size: ConvexFont.size(for: style), relativeTo: style)
    }
}

// MARK: - App-wide appearance

/// User-selectable color scheme. Dark is the default.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case dark, light, system

    static let storageKey = "appearanceMode"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .dark: "Dark"
        case .light: "Light"
        case .system: "System"
        }
    }

    /// nil follows the device setting.
    var colorScheme: ColorScheme? {
        switch self {
        case .dark: .dark
        case .light: .light
        case .system: nil
        }
    }
}

enum ConvexAppearance {
    /// Fonts and navigation bar titles. Call once at launch.
    static func apply() {
        ConvexFont.register()

        let largeTitle = UIFont(name: ConvexFont.displaySemibold, size: 34) ?? .systemFont(ofSize: 34, weight: .bold)
        let inlineTitle = UIFont(name: ConvexFont.displayMedium, size: 18) ?? .systemFont(ofSize: 17, weight: .semibold)
        let navigationBar = UINavigationBar.appearance()
        navigationBar.largeTitleTextAttributes = [.font: UIFontMetrics(forTextStyle: .largeTitle).scaledFont(for: largeTitle)]
        navigationBar.titleTextAttributes = [.font: UIFontMetrics(forTextStyle: .headline).scaledFont(for: inlineTitle)]
    }
}

// MARK: - Shared components

extension View {
    /// Warm Convex background behind grouped lists and forms.
    func convexScreenBackground() -> some View {
        scrollContentBackground(.hidden)
            .background(Color.convexBackground)
    }
}

/// Uppercase mono label, like the eyebrow labels on convex.dev.
struct Eyebrow: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text.uppercased())
            .font(.convexMono(.caption, weight: .medium))
            .tracking(0.8)
            .foregroundStyle(Color.convexSecondaryText)
    }
}

/// A list `Section` with Convex row backgrounds. Pass a title for an eyebrow header, or use the
/// `header:` / `footer:` closures like a regular `Section`.
struct ConvexSection<Content: View, Header: View, Footer: View>: View {
    @ViewBuilder let content: Content
    @ViewBuilder let header: Header
    @ViewBuilder let footer: Footer

    init(@ViewBuilder content: () -> Content, @ViewBuilder header: () -> Header, @ViewBuilder footer: () -> Footer) {
        self.content = content()
        self.header = header()
        self.footer = footer()
    }

    var body: some View {
        Section {
            content
                .listRowBackground(Color.convexSurface)
        } header: {
            header
        } footer: {
            footer
        }
    }
}

extension ConvexSection where Header == EmptyView, Footer == EmptyView {
    init(@ViewBuilder content: () -> Content) {
        self.init(content: content, header: { EmptyView() }, footer: { EmptyView() })
    }
}

extension ConvexSection where Header == EmptyView {
    init(@ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        self.init(content: content, header: { EmptyView() }, footer: footer)
    }
}

extension ConvexSection where Footer == EmptyView {
    init(@ViewBuilder content: () -> Content, @ViewBuilder header: () -> Header) {
        self.init(content: content, header: header, footer: { EmptyView() })
    }
}

extension ConvexSection where Header == Eyebrow, Footer == EmptyView {
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.init(content: content, header: { Eyebrow(title) }, footer: { EmptyView() })
    }
}

extension ConvexSection where Header == Eyebrow {
    init(_ title: String, @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        self.init(content: content, header: { Eyebrow(title) }, footer: footer)
    }
}

/// Big metric with an eyebrow caption, used in summary cards.
struct StatTile: View {
    let title: String
    let value: String
    var tint: Color?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Eyebrow(title)
            Text(value)
                .font(.convexDisplay(.title2))
                .foregroundStyle(tint ?? .convexText)
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Small uppercase mono capsule (PROD / DEV / PREVIEW).
struct DeploymentBadge: View {
    let type: String

    var body: some View {
        Text(type.uppercased())
            .font(.convexMono(.caption2, weight: .semibold))
            .tracking(0.5)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.14), in: .capsule)
            .foregroundStyle(color)
    }

    private var color: Color {
        switch type {
        case "prod": .convexAccent
        case "dev": .convexGreen
        case "preview": .convexYellow
        default: .convexSecondaryText
        }
    }
}

/// Q / M / A / H square for the function type.
struct FunctionTypeBadge: View {
    let type: String

    var body: some View {
        Text(label)
            .font(.convexMono(.caption2, weight: .semibold))
            .frame(width: 20, height: 20)
            .background(color.opacity(0.14), in: .rect(cornerRadius: 5))
            .foregroundStyle(color)
            .accessibilityLabel(type)
    }

    private var label: String {
        switch type {
        case "query": "Q"
        case "mutation": "M"
        case "action": "A"
        case "http_action": "H"
        default: "?"
        }
    }

    private var color: Color {
        switch type {
        case "query": .convexBlue
        case "mutation": .convexAccent
        case "action": .convexYellow
        case "http_action": .convexAero
        default: .convexSecondaryText
        }
    }
}

/// Horizontally scrolling single-select filter chips with counts. Place directly in a `List`.
struct ChipBar<ID: Hashable>: View {
    struct Item {
        let id: ID
        let title: String
        let count: Int
    }

    let items: [Item]
    @Binding var selection: ID

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(items, id: \.id) { item in
                    Chip(title: item.title, count: item.count, isSelected: item.id == selection) {
                        selection = item.id
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 4)
        }
        .scrollIndicators(.hidden)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
    }

    private struct Chip: View {
        let title: String
        let count: Int
        let isSelected: Bool
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.subheadline.weight(.medium))
                    Text(count, format: .number)
                        .font(.convexMono(.caption, weight: .medium))
                        .foregroundStyle(isSelected ? Color.white.opacity(0.8) : Color.convexSecondaryText)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .foregroundStyle(isSelected ? Color.white : Color.convexText)
                .background(isSelected ? Color.convexAccentFill : Color.convexSurface, in: .capsule)
                .overlay {
                    Capsule().strokeBorder(Color.convexHairline, lineWidth: isSelected ? 0 : 1)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title), \(count)")
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .animation(.snappy(duration: 0.2), value: isSelected)
        }
    }
}

/// Settings-style row: icon tile, title, optional trailing value.
struct SettingsRow<Trailing: View>: View {
    let title: String
    let systemImage: String
    let tint: Color
    @ViewBuilder let trailing: Trailing

    init(_ title: String, systemImage: String, tint: Color, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 12) {
            IconTile(systemImage: systemImage, tint: tint, size: 30)
            Text(title)
                .foregroundStyle(Color.convexText)
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: 8)
            trailing
                .font(.convexMono(.caption))
                .foregroundStyle(Color.convexSecondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

extension SettingsRow where Trailing == EmptyView {
    init(_ title: String, systemImage: String, tint: Color) {
        self.init(title, systemImage: systemImage, tint: tint) { EmptyView() }
    }
}

/// Rounded-square icon tile, used to lead rows (rules, alerts, status).
struct IconTile: View {
    let systemImage: String
    let tint: Color
    var size: CGFloat = 34

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.16), in: .rect(cornerRadius: size * 0.28))
            .accessibilityHidden(true)
    }
}

/// Status dot with an accessible label.
struct StatusDot: View {
    let isHealthy: Bool

    var body: some View {
        Circle()
            .fill(isHealthy ? Color.convexGreen : Color.convexRed)
            .frame(width: 8, height: 8)
            .accessibilityLabel(isHealthy ? "Healthy" : "Has errors")
    }
}

/// The app's logo, opposite the large title on the main tabs. On iOS 26 it sits on the bar
/// itself, not in a glass bubble.
struct LogoToolbarItem: ToolbarContent {
    var body: some ToolbarContent {
        if #available(iOS 26, *) {
            ToolbarItem(placement: .topBarTrailing) { logo }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .topBarTrailing) { logo }
        }
    }

    private var logo: some View {
        Image("Logo")
            .resizable()
            .scaledToFit()
            .frame(height: 28)
            .accessibilityHidden(true)
    }
}
