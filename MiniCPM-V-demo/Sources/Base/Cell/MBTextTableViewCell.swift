//
//  MBTextTableViewCell.swift
//  MiniCPM-V-demo
//
//  Created by Alex on 2024/6/6.
//

import Foundation
import UIKit
import SnapKit

/// Tag class so we can identify our gesture among others on the label.
private class ThinkingTapGesture: UITapGestureRecognizer {}

/// 文本 cell
class MBTextTableViewCell: UITableViewCell {
    
    /// 对应的 model
    var model: MBChatModel?
    
    /// 流式 markdown 增量渲染缓存（每 cell 一份）。流式期间只解析增量的块，
    /// 避免每帧对全文重解析造成 O(N²) 主线程开销；cell 复用时重置。
    private let streamingMarkdownCache = StreamingMarkdownRenderer()
    
    /// cell 距离屏幕左、右的边距
    var cellMargin = 24

    /// 输出气泡「右边界额外外扩量」（pt）：只放宽右边界，左边距不变。
    /// 调大 → 右边界右移、气泡更宽；0 = 原来的左右对称宽度。**微调宽度只改这一个数**。
    /// bindTextWith / heightFromRenderedContent / calcCellHeight 三处共用，
    /// 保证气泡宽度与 cell 高度用同一换行宽，不会裁字。
    static let kBubbleRightExtra: CGFloat = 10
    
    // 浅蓝色 或者 白色 的背景
    lazy var containerBGView: UIView = {
        let v = UIView()
        v.layer.cornerRadius = 16
        return v
    }()
    
    /// 自定义输出的结果（文字）视图。
    ///
    /// **必须是 `UITextView` 而不是 `UILabel`**：Markdown 表格用 `NSTextTable`
    /// 排版，而文本块（textBlocks）的边框/背景只由文本布局系统绘制 —— `UILabel`
    /// 不画（实测：表格只剩文字、一条网格线都没有）。`UITextView` 才能画出来。
    ///
    /// 配置上一律「去 UI 化」：不可编辑、不可滚动、内边距清零，外观和原来的
    /// label 保持一致，滚动交给外层 tableView。
    lazy var customTextView: UITextView = {
        // iOS 16+ 显式走 TextKit 1：TextKit 2 不支持 textBlocks（表格），
        // 不显式声明的话系统会检测到表格后打日志自动回退，行为不可控。
        let tv = UITextView(usingTextLayoutManager: false)
        tv.isEditable = false
        tv.isScrollEnabled = false          // 滚动交给外层 tableView
        tv.backgroundColor = .clear
        tv.isSelectable = false             // 与旧 label 行为一致（不需要选中）
        // 默认不接管触摸：UITextView 默认 isUserInteractionEnabled = true，
        // 会吃掉 cell 的点击/长按。thinking 折叠需要点按时，绑定时再单独打开。
        tv.isUserInteractionEnabled = false
        tv.textContainerInset = .zero       // 默认 8pt，必须清零
        tv.textContainer.lineFragmentPadding = 0  // 默认 5pt，必须清零
        tv.textContainer.maximumNumberOfLines = 0
        tv.textContainer.lineBreakMode = .byWordWrapping
        tv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return tv
    }()
    
    // MARK: - 底部 toolbar 区域
    
    /// 按钮 点击事件, model 和 点击的按钮的名字
    public var onTap: ((MBChatModel?, String?) -> Void)?

    /// 思考区域折叠/展开回调，cell 通知外部刷新高度
    public var onThinkingToggle: (() -> Void)?

    /// [复制、重新生成、👍、🦶] toolbar 容器
    lazy var toolBarContainerView: UIView = {
        let v = UIView()
        v.clipsToBounds = true
        return v
    }()
    
    /// 工具条：复制 icon
    lazy var toolbarCopyIcon : UIImageView = {
        let icon = UIImageView.init(image: UIImage(named: "toolbar_copy"))
        return icon
    }()
    
    /// 工具条：复制 Label
    lazy var toolbarCopyLabel: UILabel = {
        let lbl = UILabel()
        lbl.text = L.Home.actionCopy.loc
        lbl.textColor = UIColor.mb_color(with: "#666666")
        lbl.font = UIFont.systemFont(ofSize: 14)
        return lbl
    }()

    /// 工具条：prefill / decode 速度（复制按钮旁；iPhone / iPad 都显示）
    /// 本轮要显示的速度文案；**受设置页两个开关控制**（都关掉时返回 nil，即使模型里存着）。
    ///
    /// - 「显示 P/D 速度」管**生成结束后**的最终值；
    /// - 「实时速度」管**生成过程中**的实时 decode 值。
    ///
    /// 两者各写各的 `speedLog`，所以这里只要有一个开着就显示。
    /// 不清模型里存的值 —— 再拨回来还能看到原数，不必重新生成。
    private var visibleSpeedLog: String? {
        guard MiniCPMV47Const.showPerfSpeedEnabled() || MiniCPMV47Const.liveTpsEnabled() else { return nil }
        guard let s = model?.speedLog, !s.isEmpty else { return nil }
        return s
    }

    lazy var toolbarSpeedLabel: UILabel = {
        let lbl = UILabel()
        lbl.textColor = UIColor.mb_color(with: "#666666")
        lbl.font = UIFont.systemFont(ofSize: 14)
        lbl.isHidden = true
        return lbl
    }()

    /// 工具条：重新生成 icon
    lazy var toolbarRegenerateIcon : UIImageView = {
        let icon = UIImageView.init(image: UIImage(named: "toolbar_regenerate"))
        icon.isHidden = true
        return icon
    }()
    
    /// 工具条：重新生成 Label
    lazy var toolbarRegenerateLabel: UILabel = {
        let lbl = UILabel()
        lbl.text = L.Home.actionRegenerate.loc
        lbl.textColor = UIColor.mb_color(with: "#666666")
        lbl.font = UIFont.systemFont(ofSize: 14)
        lbl.isHidden = true
        return lbl
    }()

    /// 工具条：赞同 icon
    lazy var toolbarVoteupIcon : UIImageView = {
        let icon = UIImageView.init(image: UIImage(named: "toolbar_voteup"))
        icon.isHidden = true
        return icon
    }()

    /// 工具条：反对 icon
    lazy var toolbarVotedownIcon : UIImageView = {
        let icon = UIImageView.init(image: UIImage(named: "toolbar_votedown"))
        icon.isHidden = true
        return icon
    }()

    /// 输出的调试日志信息
    lazy var logLabel: UILabel = {
        let lb = UILabel()
        lb.textColor = UIColor.mb_color(with: "#10B601")
        lb.backgroundColor = .clear
        lb.font = .systemFont(ofSize: 12, weight: .regular)
        return lb
    }()

    // MARK: - 再次点击 cell 时弹出的 popup area
    
    /// 再次点击 cell 时弹出的 popup area，注意：这个 区域必须是 toolbar 不显示的时候才能弹出来，并且滚动 or reload 就要隐藏
    lazy var actionPopupContainerView: UIView = {
        let v = UIView()
        v.layer.cornerRadius = 8
        v.backgroundColor = UIColor.mb_color(with: "#EFF4FF")
        v.clipsToBounds = true
        return v
    }()

    /// 悬浮条：复制 icon
    lazy var floatingCopyIcon : UIImageView = {
        let icon = UIImageView.init(image: UIImage(named: "toolbar_copy"))
        return icon
    }()

    /// 悬浮条：赞同 icon
    lazy var floatingVoteupIcon : UIImageView = {
        let icon = UIImageView.init(image: UIImage(named: "toolbar_voteup"))
        return icon
    }()

    /// 悬浮条：反对 icon
    lazy var floatingVotedownIcon : UIImageView = {
        let icon = UIImageView.init(image: UIImage(named: "toolbar_votedown"))
        return icon
    }()
    
    // MARK: - 初始化方法
    
    // 初始化方法
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        
        self.backgroundColor = .clear
        
        if MBUtils.isDeviceIPad() {
            cellMargin = 120
        }
        
        contentView.addSubview(containerBGView)
        containerBGView.snp.makeConstraints { make in
            make.left.equalTo(cellMargin)
            make.right.equalTo(-cellMargin)
            make.top.equalTo(5)
            make.bottom.equalTo(-5 - 16 /* PM 要求 log 要放在 bg 外边*/)
        }
        
        // 添加自定义视图到 cell 的内容视图（contentView）中
        containerBGView.addSubview(customTextView)
        customTextView.snp.makeConstraints { make in
            make.left.equalTo(15)
            make.top.equalTo(10)
            make.right.equalTo(-15)
            make.height.equalTo(0)
        }
        
        // 显示日志用的
        contentView.addSubview(logLabel)
        logLabel.snp.makeConstraints { make in
            make.left.equalTo(cellMargin + 6)
            make.right.equalTo(-15)
            make.height.equalTo(16)
            make.bottom.equalToSuperview().offset(-4)
        }

        // 底部工具条
        containerBGView.addSubview(toolBarContainerView)
        toolBarContainerView.snp.makeConstraints { make in
            make.left.equalTo(15)
            make.right.equalTo(-15)
            make.top.equalTo(customTextView.snp.bottom).offset(10)
            make.height.equalTo(0)
        }
        
        // toolbar-copy 按钮
        toolBarContainerView.addSubview(toolbarCopyIcon)
        toolbarCopyIcon.snp.makeConstraints { make in
            make.left.equalTo(0)
            make.centerY.equalTo(toolBarContainerView)
            make.height.width.equalTo(20)
        }
        let copyIconTapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTapCopyButton))
        toolbarCopyIcon.isUserInteractionEnabled = true
        toolbarCopyIcon.addGestureRecognizer(copyIconTapGesture)

        // toolbar-copy-label
        toolBarContainerView.addSubview(toolbarCopyLabel)
        toolbarCopyLabel.snp.makeConstraints { make in
            make.left.equalTo(toolbarCopyIcon.snp.right).offset(6)
            make.height.equalTo(24)
            make.centerY.equalTo(toolbarCopyIcon)
        }
        toolbarCopyLabel.isUserInteractionEnabled = true
        let copyTapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTapCopyButton))
        toolbarCopyLabel.addGestureRecognizer(copyTapGesture)

        toolBarContainerView.addSubview(toolbarSpeedLabel)
        toolbarSpeedLabel.snp.makeConstraints { make in
            make.left.equalTo(toolbarCopyLabel.snp.right).offset(16)
            make.height.equalTo(24)
            make.centerY.equalTo(toolbarCopyIcon)
        }

        // toolbar-regenerate 按钮
        toolBarContainerView.addSubview(toolbarRegenerateIcon)
        toolbarRegenerateIcon.snp.makeConstraints { make in
            make.left.equalTo(toolbarSpeedLabel.snp.right).offset(16)
            make.centerY.equalTo(toolBarContainerView)
            make.height.width.equalTo(20)
        }
        toolbarRegenerateIcon.isUserInteractionEnabled = true
        let regenerateIconTapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTapRegenerateButton))
        toolbarRegenerateIcon.addGestureRecognizer(regenerateIconTapGesture)

        // toolbar-regenerate-label
        toolBarContainerView.addSubview(toolbarRegenerateLabel)
        toolbarRegenerateLabel.snp.makeConstraints { make in
            make.left.equalTo(toolbarRegenerateIcon.snp.right).offset(6)
            make.height.equalTo(24)
            make.centerY.equalTo(toolbarRegenerateIcon)
        }
        toolbarRegenerateLabel.isUserInteractionEnabled = true
        let regenerateLabelTapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTapRegenerateButton))
        toolbarRegenerateLabel.addGestureRecognizer(regenerateLabelTapGesture)

        // toolbar-voteup 按钮
        toolBarContainerView.addSubview(toolbarVoteupIcon)
        toolbarVoteupIcon.snp.makeConstraints { make in
            make.right.equalTo(-36)
            make.centerY.equalTo(toolBarContainerView)
            make.height.width.equalTo(20)
        }
        toolbarVoteupIcon.isUserInteractionEnabled = true
        let voteupTapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTapVoteupButton))
        toolbarVoteupIcon.addGestureRecognizer(voteupTapGesture)

        // toolbar-votedown 按钮
        toolBarContainerView.addSubview(toolbarVotedownIcon)
        toolbarVotedownIcon.snp.makeConstraints { make in
            make.right.equalTo(0)
            make.centerY.equalTo(toolBarContainerView)
            make.height.width.equalTo(20)
        }
        toolbarVotedownIcon.isUserInteractionEnabled = true
        let votedownTapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTapVotedownButton))
        toolbarVotedownIcon.addGestureRecognizer(votedownTapGesture)

        // 点击 cell 后弹出的 action popup area
        contentView.addSubview(actionPopupContainerView)
        actionPopupContainerView.snp.makeConstraints { make in
            make.right.equalTo(containerBGView.snp.right)
            make.top.equalTo(containerBGView.snp.bottom).offset(4)
            make.height.equalTo(0)
            make.width.equalTo(128)
        }
        
        // 把 floating 专用的 复制、赞同 和 反对 这 3 个 icon 加到 popup action 里
        actionPopupContainerView.addSubview(floatingCopyIcon)
        floatingCopyIcon.snp.makeConstraints { make in
            make.left.equalTo(16)
            make.centerY.equalTo(actionPopupContainerView)
            make.height.width.equalTo(20)
        }
        let floatingCopyIconTapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTapCopyButton))
        floatingCopyIcon.isUserInteractionEnabled = true
        floatingCopyIcon.addGestureRecognizer(floatingCopyIconTapGesture)

        actionPopupContainerView.addSubview(floatingVoteupIcon)
        floatingVoteupIcon.snp.makeConstraints { make in
            make.centerX.equalTo(actionPopupContainerView)
            make.centerY.equalTo(actionPopupContainerView)
            make.height.width.equalTo(20)
        }
        let floatingVoteupIconTapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTapVoteupButton))
        floatingVoteupIcon.isUserInteractionEnabled = true
        floatingVoteupIcon.addGestureRecognizer(floatingVoteupIconTapGesture)

        actionPopupContainerView.addSubview(floatingVotedownIcon)
        floatingVotedownIcon.snp.makeConstraints { make in
            make.right.equalTo(-16)
            make.centerY.equalTo(actionPopupContainerView)
            make.height.width.equalTo(20)
        }
        let floatingVotedownIconTapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTapVotedownButton))
        floatingVotedownIcon.isUserInteractionEnabled = true
        floatingVotedownIcon.addGestureRecognizer(floatingVotedownIconTapGesture)
    }
    
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func prepareForReuse() {
        super.prepareForReuse()
        streamingMarkdownCache.reset()
        // 清掉上一轮的属性串，避免复用瞬间残留旧内容（含旧表格）。
        customTextView.attributedText = nil
    }
    
    /// 气泡内文字视图的**实际**宽度（左右各 15pt 内边距已扣除）。
    ///
    /// **为什么必须三处共用**：`bindTextWith` 用它定气泡宽，而气泡宽直接决定文字
    /// 在哪里换行；两处高度测量（`heightFromRenderedContent` / `calcCellHeight`）
    /// 也必须在**同一个宽度**上量。
    ///
    /// 此前高度侧是按 `frameWidth`（由 cell 宽度估算出的「可用宽」）量的，但文字较短时
    /// `sizeThatFits` 返回的是文字的**自然宽度**，气泡会收窄到刚好包住文字 —— 收窄后
    /// 文字多换了一行，而高度没算进去，于是浅蓝底偶尔装不下文字（表现为「底框跟不上
    /// 文字」）。llm 侧还有两条**加宽**规则（最小 280、显示 P/D 速度时至少 420），
    /// 加宽后实际宽度反而大于 `frameWidth`，同样要共用。
    static func bubbleTextWidth(viewWidth: CGFloat,
                                cellMargin: CGFloat,
                                isLLM: Bool,
                                hasSpeed: Bool,
                                measure: (CGFloat) -> CGSize) -> CGFloat {
        // 1) 先在「可用宽」下量一次，拿到文字的**自然宽度**（短文本会小于可用宽）
        let availWidth = viewWidth - CGFloat(cellMargin * 2 + 48) - 30 + kBubbleRightExtra
        var containerBGWidth = 15 + ceil(measure(availWidth).width) + 15

        // 2) 套用与 bindTextWith 相同的夹紧规则，得到气泡的最终宽度
        if isLLM {
            if containerBGWidth < 280 {
                containerBGWidth = 280      // 保证放得下底部 toolbar
            }
            if hasSpeed {
                let maxWidth = viewWidth - CGFloat(cellMargin * 2)
                containerBGWidth = max(containerBGWidth, min(420, maxWidth))
            }
        }

        // 3) 文字视图实际占的宽度 = 气泡宽 - 左右各 15
        return max(0, containerBGWidth - 30)
    }

    public func bindTextWith(data: MBChatModel?, streaming: Bool = false) {
        model = data
        
        if let rawText = model?.contentText {
            // v4.6 sometimes emits Markdown break sequences as the literal
            // two-character escape `\n` instead of real newlines. Normalize
            // for *display only* here (model?.contentText keeps the raw
            // bytes so multi-turn / regenerate / copy-from-context paths see
            // exactly what the model produced). See MarkdownEscape.swift.
            let text = MarkdownEscape.normalizeResponseText(rawText)
            
            let para = NSMutableParagraphStyle()
            para.maximumLineHeight = 22
            para.minimumLineHeight = 22
            para.lineSpacing = 2
            para.lineBreakMode = .byWordWrapping
            
            let font: UIFont = UIFont.systemFont(ofSize: 16, weight: .regular)
            
            let textColor = UIColor.mb_color(with: "#1C1C23")
            
            let attributes: [NSAttributedString.Key: Any] = [
                .foregroundColor: textColor ?? .gray,
                .font: font,
                .paragraphStyle: para
            ]
            
            let isCollapsed = model?.isThinkingCollapsed ?? false
            let isLLM = model?.role == "llm"
            // 流式期间的实时 markdown 是**可选**功能（设置页开关，默认关）。
            //   关：流式期间走纯文本，生成完成后整体渲染一次 markdown（旧行为，更稳）；
            //   开：走 StreamingMarkdownRenderer 增量解析，边生成边上样式。
            let liveMarkdown = streaming && MiniCPMV47Const.streamingMarkdownEnabled()
            customTextView.attributedText = MBTextTableViewCell.buildThinkAttributedString(
                from: text, normalAttributes: attributes, paragraphStyle: para,
                collapsed: isCollapsed, renderMarkdown: isLLM && (!streaming || liveMarkdown),
                cache: liveMarkdown ? streamingMarkdownCache : nil)
            
            // Tap gesture for collapsing/expanding thinking block
            if text.hasPrefix("<think>") && text.contains("</think>") {
                customTextView.isUserInteractionEnabled = true
                if customTextView.gestureRecognizers?.contains(where: { $0 is ThinkingTapGesture }) != true {
                    let tap = ThinkingTapGesture(target: self, action: #selector(handleThinkingTap))
                    customTextView.addGestureRecognizer(tap)
                }
            }
            
            // 气泡宽度 = 文字宽度 + 左右各 15pt 内边距。宽度算法必须与两处高度测量
            // 共用（见 bubbleTextWidth 的说明），否则渲染宽度与测量宽度会不一致。
            let textWidth = Self.bubbleTextWidth(
                viewWidth: contentView.frame.size.width,
                cellMargin: CGFloat(cellMargin),
                isLLM: model?.role == "llm",
                hasSpeed: visibleSpeedLog != nil,
                measure: { customTextView.sizeThatFits(CGSize(width: $0, height: .greatestFiniteMagnitude)) })

            var containerBGWidth = textWidth + 30

            // 文本视图高度按**实际渲染宽度**量，与气泡宽度保持一致
            let size = customTextView.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude))

            if model?.role == "user" {

                self.containerBGView.backgroundColor = UIColor.mb_color(with: "#FFFFFF")
                containerBGView.snp.remakeConstraints { make in
                    make.right.equalTo(-cellMargin)
                    make.width.equalTo(containerBGWidth)
                    make.top.equalTo(5)
                    make.bottom.equalTo(-10 - 16/* floating popup area */)
                }
                
                // user 不显示 toolbar
                toolBarContainerView.snp.updateConstraints { make in
                    make.height.equalTo(0)
                }
            } else if model?.role == "llm" {
                
                self.containerBGView.backgroundColor = UIColor.mb_color(with: "#EFF4FF")
                // 宽度夹紧（最小 280 / 显示速度时至少 420）已在 bubbleTextWidth 里统一处理。

                containerBGView.snp.remakeConstraints { make in
                    make.left.equalTo(cellMargin)
                    make.width.equalTo(containerBGWidth)
                    make.top.equalTo(5)
                    make.bottom.equalTo(-5 - 16 /* PM 要求 log 要放在 bg 外边*/ - 24/* flaoting popup area*/)
                }
                
                // llm 底部的【复制、重新生成、👍、🦶】toolbar
                // 速度显示开着时，生成过程中同一行先只显示速度，结束后再露出复制。
                if !text.isEmpty {
                    let speedText = visibleSpeedLog
                    if model?.hasBottomToolbar == true || speedText != nil {
                        
                        if model?.voteStatus == .neutral {
                            toolbarVoteupIcon.image = UIImage(named: "toolbar_voteup")
                            toolbarVotedownIcon.image = UIImage(named: "toolbar_votedown")
                        }
                        
                        toolBarContainerView.snp.updateConstraints { make in
                            make.height.equalTo(24)
                        }
                        // 速度行显示时把悬浮按钮让出来，避免和 toolbar 争位置
                        actionPopupContainerView.snp.updateConstraints { make in
                            make.height.equalTo(0)
                        }
                        // 生成过程中还没有最终排版，先不给复制按钮
                        let copyVisible = model?.hasBottomToolbar == true
                        toolbarCopyIcon.isHidden = !copyVisible
                        toolbarCopyLabel.isHidden = !copyVisible
                        if let speed = speedText {
                            toolbarSpeedLabel.text = speed
                            toolbarSpeedLabel.isHidden = false
                            // 复制键隐藏后左边要贴到 0，否则会留下它的宽度
                            toolbarSpeedLabel.snp.remakeConstraints { make in
                                if copyVisible {
                                    make.left.equalTo(toolbarCopyLabel.snp.right).offset(16)
                                } else {
                                    make.left.equalTo(0)
                                }
                                make.right.lessThanOrEqualTo(0)
                                make.height.equalTo(24)
                                make.centerY.equalTo(toolbarCopyIcon)
                            }
                        } else {
                            toolbarSpeedLabel.text = nil
                            toolbarSpeedLabel.isHidden = true
                        }
                    } else {
                        // 不显示 toolbar
                        toolBarContainerView.snp.updateConstraints { make in
                            make.height.equalTo(0)
                        }
                        toolbarSpeedLabel.isHidden = true
                        
                        // 注意：floating action 只有不显示 toolbar 的情况下才能显示，要不然就会冲突
                        if model?.hasFloatingActionButton == true {
                            // 具体这个 popop 要怎么显示，由外部 click 事件触发
                            actionPopupContainerView.snp.updateConstraints { make in
                                make.height.equalTo(36)
                            }
                        } else {
                            actionPopupContainerView.snp.updateConstraints { make in
                                make.height.equalTo(0)
                            }
                        }
                        
                    }
                } else {
                    // 没有文字
                    // 不显示 toolbar
                    toolBarContainerView.snp.updateConstraints { make in
                        make.height.equalTo(0)
                    }
                    toolbarSpeedLabel.isHidden = true

                    // 不显示悬浮的 popup area
                    actionPopupContainerView.snp.updateConstraints { make in
                        make.height.equalTo(0)
                    }
                }
                
            }

            // calc label height
            customTextView.snp.updateConstraints { make in
                make.height.equalTo(size.height)
            }
        } else {
            // 不显示 toolbar
            toolBarContainerView.snp.updateConstraints { make in
                make.height.equalTo(0)
            }
            
            // 不显示 action popup
            actionPopupContainerView.snp.updateConstraints { make in
                make.height.equalTo(0)
            }
        }
        
        // 显示日志
        if model?.role != "llm" {
            logLabel.textAlignment = .right
            logLabel.snp.remakeConstraints { make in
                make.right.equalTo(-cellMargin)
                make.height.equalTo(16)
                make.top.equalTo(self.containerBGView.snp.bottom).offset(4)
            }
            
        } else {
            logLabel.textAlignment = .left
            logLabel.snp.remakeConstraints { make in
                make.left.equalTo(cellMargin + 6)
                make.right.equalTo(-15)
                make.height.equalTo(16)
                make.top.equalTo(self.containerBGView.snp.bottom).offset(4)
            }
        }
        
        if let log = model?.performLog, !log.isEmpty {
            let attachment = NSTextAttachment()
            attachment.image = UIImage(named: "log_icon")?.withTintColor(UIColor.mb_color(with: "#10B601") ?? .gray)
            attachment.bounds = CGRect(x: 0, y: -1, width: 10, height: 10)
            let attachmentString = NSAttributedString(attachment: attachment)
            let firstString = NSAttributedString(string: " \(log)", attributes: [NSAttributedString.Key.foregroundColor: UIColor.mb_color(with: "#10B601") ?? .gray, NSAttributedString.Key.font: UIFont.systemFont(ofSize: 12, weight: .regular)])
            let finalString = NSMutableAttributedString()
            finalString.append(attachmentString)
            finalString.append(firstString)
            logLabel.attributedText = finalString
        } else {
            logLabel.attributedText = nil
        }

        // 不显示性能日志
        if let str = UserDefaults.standard.string(forKey: "show_statistic_log") {
            if str == "0" {
                logLabel.attributedText = nil
            }
        }
    }
    
    /// 流式更新时，从已渲染的 customTextView.attributedText 直接计算高度，
    /// 避免重复调用 buildThinkAttributedString 做第二次 Markdown 渲染。
    public func heightFromRenderedContent(viewWidth: CGFloat) -> CGFloat {
        guard let attrText = customTextView.attributedText else { return 0 }

        // 必须在**实际渲染宽度**上量高度：气泡会按文字自然宽度收窄（或按 llm 的规则
        // 加宽），换行数随之改变。按 cell 可用宽（frameWidth）量会算错行数 ——
        // 这就是「浅蓝底跟不上文字」的成因。见 bubbleTextWidth。
        let textWidth = Self.bubbleTextWidth(
            viewWidth: viewWidth,
            cellMargin: CGFloat(cellMargin),
            isLLM: model?.role == "llm",
            hasSpeed: visibleSpeedLog != nil,
            measure: { customTextView.sizeThatFits(CGSize(width: $0, height: .greatestFiniteMagnitude)) })

        // 用 sizeThatFits（表格是段落级 textBlocks，boundingRect 量不准）；
        // UITextView 非线程安全，必须在主线程调用。
        let measureSize = CGSize(width: textWidth, height: .greatestFiniteMagnitude)
        let textSize = Thread.isMainThread
            ? customTextView.sizeThatFits(measureSize)
            : attrText.boundingRect(with: measureSize, options: .usesLineFragmentOrigin, context: nil).size

        var toolbarAreaHeight: CGFloat = 0
        if model?.hasBottomToolbar == true || visibleSpeedLog != nil {
            toolbarAreaHeight = 34
        }

        let cellTop: CGFloat = 18.0
        var logHeight: CGFloat = 20
        if model?.role == "user", model?.type == "TEXT" {
            logHeight = 0
        }
        let cellBottom = toolbarAreaHeight + logHeight + 34.0
        return cellTop + textSize.height + cellBottom
    }

    /// 计算 cell 高度
    public static func calcCellHeight(data: MBChatModel?, viewWidth: CGFloat) -> CGFloat {
        if let rawText = data?.contentText {
            // Mirror the display-side normalization in bindTextWith so the
            // measured height matches the rendered glyph layout (otherwise
            // v4.6 outputs with literal `\n` would measure as one short
            // line and clip when the text actually expands across many).
            let text = MarkdownEscape.normalizeResponseText(rawText)
            
            let para = NSMutableParagraphStyle()
            para.maximumLineHeight = 22
            para.minimumLineHeight = 22
            para.lineSpacing = 2
            para.lineBreakMode = .byWordWrapping
            
            let font: UIFont = UIFont.systemFont(ofSize: 16, weight: .regular)
            
            let attributes: [NSAttributedString.Key: Any] = [
                .foregroundColor: UIColor.black,
                .font: font,
                .paragraphStyle: para
            ]
            
            // 用 UITextView 量（与 bindTextWith 一致）：表格是段落级 textBlocks，
            // 只有文本视图的布局才算得准高度。
            let probe = UITextView(usingTextLayoutManager: false)
            probe.isEditable = false
            probe.isScrollEnabled = false
            probe.textContainerInset = .zero
            probe.textContainer.lineFragmentPadding = 0
            probe.textContainer.maximumNumberOfLines = 0
            probe.textContainer.lineBreakMode = .byWordWrapping

            let isCollapsed = data?.isThinkingCollapsed ?? false
            let isLLM = data?.role == "llm"
            probe.attributedText = buildThinkAttributedString(
                from: text, normalAttributes: attributes, paragraphStyle: para,
                collapsed: isCollapsed, renderMarkdown: isLLM)
            
            // 适配 iPhone + iPad
            let cellMargin: CGFloat = MBUtils.isDeviceIPad() ? 120 : 24

            // 与 bindTextWith / heightFromRenderedContent 共用同一个宽度算法：
            // 渲染宽度 ≠ 测量宽度时换行数会不一致（浅蓝底装不下文字）。
            let textWidth = bubbleTextWidth(
                viewWidth: viewWidth,
                cellMargin: cellMargin,
                isLLM: isLLM,
                hasSpeed: !(data?.speedLog ?? "").isEmpty && MiniCPMV47Const.showPerfSpeedEnabled(),
                measure: { probe.sizeThatFits(CGSize(width: $0, height: .greatestFiniteMagnitude)) })

            let pureContentTextframe = probe.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude))
            
            /*
             
             cell-2-cell space 8pt
             
             top space 10pt
             
             text area
             
             text bottom space 10pt
             
             toolbar area 24pt
             
             toolbar space 10pt
             
             background view space 5pt
             
             debug output area 20pt
             
             floating popup area 24pt
             */
            
            var toolbarAreaHeight = 0
            if data?.hasBottomToolbar == true || !(data?.speedLog ?? "").isEmpty {
                toolbarAreaHeight = 24 + 10
            }
            
            let cellTop = 8.0 + 10.0/* text inner top*/
            
            // 用户输入的 文本内容 不需要 log
            var logHeight = 20
            if data?.role == "user", data?.type == "TEXT" {
                logHeight = 0
            }
            
            // 10 = text inner bottom, 20 = log 的高度, 5
            let cellBottom = toolbarAreaHeight + logHeight + 34/* floating popup area */
            return cellTop + pureContentTextframe.height + Double(cellBottom)
        }
        
        return 0
    }
}

extension MBTextTableViewCell {
    
    /// 显示 or 隐藏悬浮的 action popup area
    public func showPopupActionWith(show: Bool) {

        if model?.hasBottomToolbar == true {
            return
        }

        // 同步状态
        model?.hasFloatingActionButton = show

        if show {
            
            if model?.voteStatus == .neutral {
                floatingVoteupIcon.image = UIImage(named: "toolbar_voteup")
                floatingVotedownIcon.image = UIImage(named: "toolbar_votedown")
            } else if model?.voteStatus == .voteup {
                floatingVoteupIcon.image = UIImage(named: "toolbar_voteup_selected")
                floatingVotedownIcon.image = UIImage(named: "toolbar_votedown")
            } else if model?.voteStatus == .votedown {
                floatingVoteupIcon.image = UIImage(named: "toolbar_voteup")
                floatingVotedownIcon.image = UIImage(named: "toolbar_votedown_selected")
            }
            
            UIView.animate(withDuration: 0.15, delay: 0, options: .curveEaseInOut, animations: {
                self.actionPopupContainerView.alpha = 1
                self.actionPopupContainerView.snp.updateConstraints { make in
                    make.height.equalTo(36)
                }
            })
            
            // 5 秒后自动隐藏
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                self.showPopupActionWith(show: false)
            }
            
        } else {
            UIView.animate(withDuration: 0.15) {
                self.actionPopupContainerView.alpha = 0
            } completion: { finish in
                // 不显示 action popup
                self.actionPopupContainerView.snp.updateConstraints { make in
                    make.height.equalTo(0)
                }
            }
        }
    }
    
}

extension MBTextTableViewCell {
    
    /// copy 点击事件
    @objc public func handleTapCopyButton(_ id: UITapGestureRecognizer?) {
        onTap?(model, "copy")
    }
    
    /// regenerate 点击事件
    @objc public func handleTapRegenerateButton(_ id: UITapGestureRecognizer?) {
        onTap?(model, "regenerate")
    }

    /// vote-up 点击事件
    @objc public func handleTapVoteupButton(_ id: UITapGestureRecognizer?) {
        onTap?(model, "voteup")
        
        if model?.voteStatus != .voteup {
            model?.voteStatus = .voteup
            self.toolbarVoteupIcon.image = UIImage(named: "toolbar_voteup_selected")
            self.floatingVoteupIcon.image = UIImage(named: "toolbar_voteup_selected")
            
            // 让 down 变变 neutral
            self.toolbarVotedownIcon.image = UIImage(named: "toolbar_votedown")
            self.floatingVotedownIcon.image = UIImage(named: "toolbar_votedown")

        } else {
            model?.voteStatus = .neutral
            
            self.toolbarVoteupIcon.image = UIImage(named: "toolbar_voteup")
            self.floatingVoteupIcon.image = UIImage(named: "toolbar_voteup")
            
            // 让 down 变变 neutral
            self.toolbarVotedownIcon.image = UIImage(named: "toolbar_votedown")
            self.floatingVotedownIcon.image = UIImage(named: "toolbar_votedown")
        }
    }

    /// vote-down 点击事件
    @objc public func handleTapVotedownButton(_ id: UITapGestureRecognizer?) {
        onTap?(model, "votedown")
        
        if model?.voteStatus != .votedown {
            model?.voteStatus = .votedown
            self.toolbarVotedownIcon.image = UIImage(named: "toolbar_votedown_selected")
            self.floatingVotedownIcon.image = UIImage(named: "toolbar_votedown_selected")
            
            // 让 up 变变 neutral
            self.toolbarVoteupIcon.image = UIImage(named: "toolbar_voteup")
            self.floatingVoteupIcon.image = UIImage(named: "toolbar_voteup")

        } else {
            model?.voteStatus = .neutral
            self.toolbarVotedownIcon.image = UIImage(named: "toolbar_votedown")
            self.floatingVotedownIcon.image = UIImage(named: "toolbar_votedown")
            
            // 让 up 变变 neutral
            self.toolbarVoteupIcon.image = UIImage(named: "toolbar_voteup")
            self.floatingVoteupIcon.image = UIImage(named: "toolbar_voteup")
        }

    }

    // MARK: - Thinking collapse/expand

    @objc private func handleThinkingTap(_ gesture: UITapGestureRecognizer) {
        guard let m = model else { return }
        let current = m.isThinkingCollapsed ?? false
        m.isThinkingCollapsed = !current
        m.cellHeight = MBTextTableViewCell.calcCellHeight(
            data: m, viewWidth: contentView.frame.width)
        bindTextWith(data: m)
        onThinkingToggle?()
    }

    // MARK: - <think> block rendering

    /// Parse text containing `<think>...</think>` blocks and build an
    /// NSAttributedString with thinking content rendered in gray italic and
    /// the response in normal style.
    ///
    /// Handles three states:
    ///   1. `<think>\n思考中...\n</think>\n\n回复` → gray italic think + normal response
    ///   2. `<think>\n思考中...` (no closing tag, still generating) → gray italic "思考中..."
    ///   3. No `<think>` tag → plain normal text
    ///
    /// - Parameter collapsed: When true, thinking content is hidden (only header + response shown).
    static func buildThinkAttributedString(
        from text: String,
        normalAttributes: [NSAttributedString.Key: Any],
        paragraphStyle: NSMutableParagraphStyle,
        collapsed: Bool = false,
        renderMarkdown: Bool = false,
        cache: StreamingMarkdownRenderer? = nil
    ) -> NSAttributedString {
        
        guard text.hasPrefix("<think>") else {
            if renderMarkdown {
                if let cache {
                    return cache.render(text, baseAttributes: normalAttributes)
                }
                return MarkdownRenderer.render(text, baseAttributes: normalAttributes)
            }
            return NSAttributedString(string: text, attributes: normalAttributes)
        }
        
        let result = NSMutableAttributedString()
        let thinkFont = UIFont.italicSystemFont(ofSize: 14)
        let thinkColor = UIColor.gray
        let thinkAttributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: thinkColor,
            .font: thinkFont,
            .paragraphStyle: paragraphStyle
        ]
        
        let thinkOpenTag = "<think>\n"
        let thinkCloseTag = "</think>"
        
        if let closeRange = text.range(of: thinkCloseTag) {
            let thinkStart = text.index(text.startIndex, offsetBy: thinkOpenTag.count)
            let thinkContent = String(text[thinkStart..<closeRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            
            if !thinkContent.isEmpty {
                let arrow = collapsed ? "▸" : "▾"
                result.append(NSAttributedString(string: "💭 \(arrow) \(L.Home.thinkProcessLabel.loc)\n", attributes: thinkAttributes))
                if !collapsed {
                    result.append(NSAttributedString(string: thinkContent + "\n\n", attributes: thinkAttributes))
                }
            }
            
            var responseStart = closeRange.upperBound
            while responseStart < text.endIndex && text[responseStart] == "\n" {
                responseStart = text.index(after: responseStart)
            }
            let response = String(text[responseStart...])
            if !response.isEmpty {
                if renderMarkdown {
                    if let cache {
                        result.append(cache.render(response, baseAttributes: normalAttributes))
                    } else {
                        result.append(MarkdownRenderer.render(response, baseAttributes: normalAttributes))
                    }
                } else {
                    result.append(NSAttributedString(string: response, attributes: normalAttributes))
                }
            }
        } else {
            let thinkStart = text.index(text.startIndex, offsetBy: min(thinkOpenTag.count, text.count))
            let thinkContent = String(text[thinkStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
            
            result.append(NSAttributedString(string: "💭 ▾ \(L.Home.thinkInProgressLabel.loc)\n", attributes: thinkAttributes))
            if !thinkContent.isEmpty {
                result.append(NSAttributedString(string: thinkContent, attributes: thinkAttributes))
            }
        }
        
        return result
    }

}
