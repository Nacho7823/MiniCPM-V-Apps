//
//  MBHomeWelcomeTipsView.swift
//  MiniCPM-V-demo
//
//  Created by Alex on 2024/6/8.
//

import Foundation
import UIKit
import SnapKit

/// 首页 header 用到的 tips view
class MBHomeWelcomeTipsView: UIView {
    
    /// 点击事件。回调的是要发给模型的文本（可以和按钮上显示的短标题不同）。
    public var onTap: ((String?) -> Void)?

    /// 自定义点击动作，非 nil 时优先于 `onTap`（用于「点开还要再选一次」的场景）。
    public var onTapAction: (() -> Void)?

    /// 真正发送的 prompt；nil 则发送 titleLabel.text
    private var sendPayload: String?
    /// icon
    lazy var iconImageView: UIImageView = {
        let img = UIImageView()
        img.contentMode = .scaleAspectFill
        img.clipsToBounds = true
        
        return img
    }()

    /// text
    lazy var titleLabel: UILabel = {
        let lb = UILabel()
        if MBUtils.isDeviceIPad() {
            lb.font = UIFont.systemFont(ofSize: 16, weight: .medium)
        } else {
            lb.font = UIFont.systemFont(ofSize: 10, weight: .medium)
        }
        lb.textColor = UIColor.mb_color(with: "#1C1C23")
        lb.lineBreakMode = .byTruncatingTail
        lb.numberOfLines = 1
        return lb
    }()
    
    /// 初始化方法，通过代码创建视图实例时会调用此方法
    override init(frame: CGRect) {
        super.init(frame: frame)
        setupView()
    }
    
    /// 初始化方法，通过 Interface Builder 创建视图实例时会调用此方法
    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        setupView()
    }
    
    /// 设置视图和其子视图的布局和样式
    private func setupView() {
        
        self.backgroundColor = .white
        self.layer.cornerRadius = 16
        
        addSubview(iconImageView)
        iconImageView.snp.makeConstraints { make in
            make.centerY.equalTo(self)
            make.left.equalTo(7)
            make.width.height.equalTo(40)
        }

        addSubview(titleLabel)
        titleLabel.snp.makeConstraints { make in
            make.centerY.equalTo(self)
            make.height.equalTo(18)
            make.left.equalTo(self.iconImageView.snp.right).offset(8)
            make.right.lessThanOrEqualTo(-8)
        }
        
        // 增加点击事件
        self.isUserInteractionEnabled = true
        let tapGestureRecognizer = UITapGestureRecognizer(target: self, action: #selector(viewTapped))
        addGestureRecognizer(tapGestureRecognizer)
    }
    
    /// 点击事件
    @objc private func viewTapped() {
        
        self.isUserInteractionEnabled = false
        DispatchQueue.main.asyncAfter(wallDeadline: .now() + 5) {
            self.isUserInteractionEnabled = true
        }
        
        // 自定义动作优先（选择器这类要弹菜单的走这条）。
        if let action = onTapAction {
            action()
            return
        }
        
        onTap?(sendPayload ?? titleLabel.text)
    }
    
    /// 数据绑定。`sendText` 有值时，点击发送它而不是短标题。
    public func bindWith(icon: UIImage?, title: String?, sendText: String? = nil) {
        self.iconImageView.image = icon
        self.titleLabel.text = title
        self.sendPayload = sendText
    }
    
}
