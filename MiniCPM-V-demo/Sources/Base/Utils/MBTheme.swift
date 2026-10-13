//
//  MBTheme.swift
//  MiniCPM-V-demo
//
//  夜间模式：外观偏好 + 亮/暗色值映射表。
//
//  设计要点：全 App 的色值都走 `UIColor.mb_color(with:)` 这一个入口，所以暗色只需要
//  在这里给「亮色 hex -> 暗色 hex」的映射表，由 `mb_color` 返回动态色 —— 139 个调用点
//  一行都不用改。查不到映射的色值原样返回，行为与加夜间模式前完全一致。
//

import UIKit

// MARK: - 外观偏好

enum MBAppearance: Int, CaseIterable {
    case followSystem = 0
    case alwaysDark   = 1
    case alwaysLight  = 2

    var userInterfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .followSystem: return .unspecified
        case .alwaysDark:   return .dark
        case .alwaysLight:  return .light
        }
    }

    /// 设置页那一行显示的文案 key（`L.Settings.*`）。
    var displayNameKey: String {
        switch self {
        case .followSystem: return L.Settings.appearanceFollowSystem.loc
        case .alwaysDark:   return L.Settings.appearanceDark.loc
        case .alwaysLight:  return L.Settings.appearanceLight.loc
        }
    }
}

enum MBTheme {

    private static let appearanceDefaultsKey = "app_appearance"

    /// 当前偏好。没写过时默认「跟随系统」。
    static var current: MBAppearance {
        get {
            MBAppearance(rawValue: UserDefaults.standard.integer(forKey: appearanceDefaultsKey)) ?? .followSystem
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: appearanceDefaultsKey)
        }
    }

    /// 把所有窗口的外观切过去。UIKit 会自动重解析动态色，并触发 `traitCollectionDidChange`，
    /// 所以不需要遍历视图树手工重设颜色。
    static func apply(_ appearance: MBAppearance = MBTheme.current) {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                window.overrideUserInterfaceStyle = appearance.userInterfaceStyle
            }
        }
    }

    // MARK: - 亮 / 暗映射

    /// 亮色 hex -> 暗色 hex。
    ///
    /// 只列**真的需要变**的色值；这里没有的（例如品牌橙、纯装饰色）保持原样。
    /// 取值参照 iOS 系统语义色的观感，避免自造色导致和系统控件不搭。
    static func darkVariant(for lightHex: String) -> String? {
        return darkMap[lightHex.uppercased()]
    }

    private static let darkMap: [String: String] = [
        // ── 页面 / 容器底色 ──
        // 亮色下页面是微灰、卡片更白；暗色下反过来 —— 页面纯黑、卡片抬亮一档，
        // 这样分组的层次感才出来（对齐 iOS 原生 grouped 观感）。
        "#F9FAFC": "#000000",   // 页面主底（用得最多）
        "#F6F6F6": "#000000",   // tableView 底
        "#FFFFFF": "#1C1C1E",   // 卡片 / 气泡底
        "#FEFEFE": "#1C1C1E",
        "#F2F2F7": "#1C1C1E",   // 分组底
        "#F0F0F0": "#2C2C2E",   // 浅灰填充（输入框等）
        "#E0E0E0": "#2C2C2E",
        "#D1D5DB": "#3A3A3C",
        "#CCCCCC": "#3A3A3C",   // 禁用态
        "#EFF4FF": "#1B3A5A",   // LLM 气泡浅蓝底 → 暗蓝

        // ── 文字 ──
        "#000000": "#FFFFFF",
        "#333333": "#E5E5E7",   // 主文字
        "#1C1C23": "#E8E8EC",
        "#3C3C43": "#EBEBF5",   // 次级文字（系统同款）
        "#666666": "#AEAEB2",
        "#6B7280": "#9CA3AF",
        "#8E8E93": "#98989F",   // 次级/占位
        "#8A8A8E": "#9A9AA0",

        // ── 强调 / 语义色 ──
        "#007AFF": "#0A84FF",   // 品牌蓝（暗色下用系统蓝的暗色变体）
        "#108DED": "#0A84FF",
        "#4967FA": "#5E7CFF",
        "#10B601": "#30D158",   // 状态绿
        "#34C759": "#30D158",
        "#51D346": "#30D158",
        "#FF3B30": "#FF453A",   // 错误红
        "#FF9500": "#FF9F0A",   // 橙
        "#F8CB58": "#FFD60A",   // 黄

        // ── Markdown 代码块 / 行内代码 ──
        // 亮色是「深字浅底」，暗色必须翻成「浅字深底」，否则一片浅色块很扎眼。
        "#1F2429": "#D8DEE4",   // 代码块文字
        "#F2F5F7": "#1A1F23",   // 代码块底
        "#C7264D": "#FF6B8A",   // 行内代码文字
        "#F7EDF0": "#3A2028",   // 行内代码底
    ]
}

// MARK: - 语义色（供没法走 hex 的调用点使用）

extension UIColor {

    /// 页面主背景（亮 #F9FAFC / 暗 #000000）。
    static var mbPageBackground: UIColor {
        mb_color(with: "#F9FAFC") ?? .systemGroupedBackground
    }

    /// 卡片 / 单元格背景（亮 #FFFFFF / 暗 #1C1C1E）。
    ///
    /// 与 `.systemBackground` 的区别：系统色在亮色下是纯白、暗色下是纯黑，
    /// 而这里要的是「比页面抬亮一档」的卡片色，视觉层次才够。
    static var mbCardBackground: UIColor {
        mb_color(with: "#FFFFFF") ?? .secondarySystemGroupedBackground
    }

    /// 主文字（亮 #333333 / 暗 #E5E5E7）。
    static var mbPrimaryText: UIColor {
        mb_color(with: "#333333") ?? .label
    }

    /// 图标 / 导航栏按钮着色。
    ///
    /// 用 `.label` 而不是黑 —— 它是系统语义色，亮色下就是黑、暗色下自动变白，
    /// 而且能跟随「增强对比度」等辅助功能设置。
    static var mbIconTint: UIColor { .label }
}

// MARK: - 导航栏标题对比色

extension UIColor {

    /// 给定导航栏背景色，返回一个**在两种外观下都合适**的标题色。
    ///
    /// 不能只算一次亮度：传进来的背景色本身可能已经是动态色（`mb_color` 查表而来），
    /// 只算一次的话切到暗色后标题不会跟着翻，出现「深底黑字」。
    static func mb_contrastTitleColor(forBackground background: UIColor) -> UIColor {
        func title(isDarkBackground: Bool) -> UIColor { isDarkBackground ? .white : .black }

        let lightBg = background.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        let darkBg = background.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))

        // 两种外观下结论一致时（背景是静态色）没必要建动态色，省一层解析。
        let lightTitle = title(isDarkBackground: lightBg.isDarkColor)
        let darkTitle = title(isDarkBackground: darkBg.isDarkColor)
        guard lightTitle != darkTitle else { return lightTitle }

        return UIColor { traits in
            traits.userInterfaceStyle == .dark ? darkTitle : lightTitle
        }
    }
}
