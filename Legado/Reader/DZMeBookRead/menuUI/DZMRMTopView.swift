//
//  DZMRMTopView.swift
//  DZMeBookRead
//
//  Created by dengzemiao on 2019/4/18.
//  Copyright © 2019年 DZM. All rights reserved.
//

import UIKit

/// topView 高度
let DZM_READ_MENU_TOP_VIEW_HEIGHT:CGFloat = NavgationBarHeight

class DZMRMTopView: DZMRMBaseView {
    
    /// 返回
    private var back:UIButton!
    
    /// 当前章节标题
    private var chapterTitleLabel: UILabel!

    /// 全书缓存状态图标
    private var cacheEntireBookButton: UIButton!
    private var cacheProgressRing: CAShapeLayer!

    override init(frame: CGRect) { super.init(frame: frame) }
    
    override func addSubviews() {
        
        super.addSubviews()
        
        // 返回
        back = UIButton(type:.custom)
        back.setImage(UIImage(named:"back")!.withRenderingMode(.alwaysTemplate), for: .normal)
        back.addTarget(self, action: #selector(clickBack), for: .touchUpInside)
        back.tintColor = DZM_READ_COLOR_MENU_COLOR
        addSubview(back)
        
        chapterTitleLabel = UILabel()
        chapterTitleLabel.font = DZM_FONT_SA_14
        chapterTitleLabel.textColor = DZM_READ_COLOR_MENU_COLOR
        chapterTitleLabel.textAlignment = .center
        chapterTitleLabel.lineBreakMode = .byTruncatingTail
        chapterTitleLabel.text = "阅读中"
        addSubview(chapterTitleLabel)

        cacheEntireBookButton = UIButton(type: .custom)
        cacheEntireBookButton.tintColor = DZM_READ_COLOR_MENU_COLOR
        cacheEntireBookButton.accessibilityLabel = "缓存整本书"
        cacheEntireBookButton.addTarget(self, action: #selector(clickCacheEntireBook), for: .touchUpInside)
        addSubview(cacheEntireBookButton)
        cacheProgressRing = CAShapeLayer()
        cacheProgressRing.fillColor = UIColor.clear.cgColor
        cacheProgressRing.strokeColor = DZM_READ_COLOR_MENU_COLOR.cgColor
        cacheProgressRing.lineWidth = 2.5
        cacheProgressRing.lineCap = .round
        cacheProgressRing.isHidden = true
        cacheEntireBookButton.layer.addSublayer(cacheProgressRing)
        updateCacheEntireBook(state: .available)
    }
    
    /// 点击返回
    @objc private func clickBack() {
        
        readMenu?.delegate?.readMenuClickBack?(readMenu: readMenu)
    }
    
    /// 点击缓存整本书
    @objc private func clickCacheEntireBook() {
        readMenu?.delegate?.readMenuClickCacheEntireBook?(readMenu: readMenu)
    }
    
    /// Updates the title in the same bar as the native reader controls.
    func updateChapterTitle(_ title: String) {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        chapterTitleLabel.text = trimmedTitle.isEmpty ? "阅读中" : trimmedTitle
    }

    /// Updates the full-book cache affordance without changing the reader menu layout.
    /// The reader bridge supplies a checkmark when the current chapter through the end is cached.
    func updateCacheEntireBook(state: ReaderBookCacheState) {
        let symbolName: String
        let accessibilityValue: String
        switch state {
        case .unavailable:
            symbolName = "exclamationmark.triangle"
            accessibilityValue = "目录不完整，不能缓存全书"
        case .available:
            symbolName = "arrow.down.to.line"
            accessibilityValue = "未缓存"
        case .downloading:
            symbolName = "arrow.down.to.line"
            accessibilityValue = "缓存中"
        case .completed:
            symbolName = "checkmark"
            accessibilityValue = "已缓存"
        }

        let configuration = UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
        cacheEntireBookButton.setImage(
            UIImage(systemName: symbolName, withConfiguration: configuration),
            for: .normal
        )
        cacheEntireBookButton.isEnabled = state == .available
        cacheEntireBookButton.accessibilityValue = accessibilityValue
        cacheProgressRing.isHidden = true
        cacheEntireBookButton.setTitle(nil, for: .normal)
    }

    func updateCacheProgress(_ progress: Double?) {
        guard let progress, progress >= 0, progress < 1 else {
            cacheProgressRing.isHidden = true
            return
        }
        let percent = Int((progress * 100).rounded())
        cacheEntireBookButton.setImage(nil, for: .normal)
        cacheEntireBookButton.setTitle(nil, for: .normal)
        cacheEntireBookButton.isEnabled = false
        cacheEntireBookButton.accessibilityValue = "缓存中\(percent)%"
        cacheProgressRing.isHidden = false
        let center = CGPoint(x: cacheEntireBookButton.bounds.midX, y: cacheEntireBookButton.bounds.midY)
        let radius = min(cacheEntireBookButton.bounds.width, cacheEntireBookButton.bounds.height) / 2 - 8
        let path = UIBezierPath(arcCenter: center, radius: radius, startAngle: -.pi / 2, endAngle: 3 * .pi / 2, clockwise: true)
        cacheProgressRing.frame = cacheEntireBookButton.bounds
        cacheProgressRing.path = path.cgPath
        cacheProgressRing.strokeEnd = CGFloat(max(0, min(progress, 1)))
    }
    
    override func layoutSubviews() {
        
        super.layoutSubviews()
        
        let y = readMenu.vc.view.safeAreaInsets.top
        let wh: CGFloat = 44
        
        back.frame = CGRect(x: 0, y: y, width: wh, height: wh)
        
        let cacheWidth: CGFloat = wh
        cacheEntireBookButton.frame = CGRect(
            x: frame.size.width - cacheWidth,
            y: y,
            width: cacheWidth,
            height: wh
        )
        cacheProgressRing.frame = cacheEntireBookButton.bounds
        chapterTitleLabel.frame = CGRect(
            x: wh,
            y: y,
            width: max(0, frame.size.width - wh - cacheWidth),
            height: wh
        )
    }
    
    required init?(coder aDecoder: NSCoder) {
        
        fatalError("init(coder:) has not been implemented")
    }
}
