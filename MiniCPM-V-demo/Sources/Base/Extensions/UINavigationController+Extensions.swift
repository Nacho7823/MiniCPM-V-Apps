//
//  UINavigationController+Extensions.swift
//  MiniCPM-V-demo
//
//  Created by Alex on 2024/6/18.
//

import UIKit

extension UINavigationController {
    
    /// 自定义导航栏颜色的扩展方法
    /// - Parameter color: 要设置的背景颜色
    func setNavigationBackgroundColor(_ color: UIColor) {
        // 夜间模式：用双外观判断得出标题对比色（不能只算一次亮度，否则切暗色后
        // 背景变深、标题仍为黑色）。
        let titleColor = UIColor.mb_contrastTitleColor(forBackground: color)

        if #available(iOS 13.0, *) {
            let appearance = UINavigationBarAppearance()
            appearance.configureWithOpaqueBackground()
            appearance.backgroundColor = color
            
            // 设置标题文字颜色，根据背景色自动判断使用黑色或白色
            appearance.titleTextAttributes = [
                .foregroundColor: titleColor
            ]
            appearance.largeTitleTextAttributes = [
                .foregroundColor: titleColor
            ]
            
            navigationBar.standardAppearance = appearance
            navigationBar.scrollEdgeAppearance = appearance
        } else {
            navigationBar.barTintColor = color
            
            // iOS 13 以下版本设置标题颜色
            navigationBar.titleTextAttributes = [
                .foregroundColor: titleColor
            ]
        }
    }
} 