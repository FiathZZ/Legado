//
//  DZMReadView.swift
//  DZMeBookRead
//
//  Created by dengzemiao on 2019/4/17.
//  Copyright © 2019年 DZM. All rights reserved.
//

import UIKit

class DZMReadView: UIView {
    
    /// 当前页模型(使用contentSize绘制)
    var pageModel:DZMReadPageModel! {
        
        didSet{
            
            applyFrameRef(content: pageModel.showContent, size: pageModel.contentSize ?? DZM_READ_VIEW_RECT.size)
        }
    }
    
    /// 当前页内容(使用固定范围绘制)
    var content:NSAttributedString! {
        
        didSet{
            
            applyFrameRef(content: content, size: DZM_READ_VIEW_RECT.size)
        }
    }
    
    /// CTFrame
    var frameRef:CTFrame? {
        
        didSet{
            
            if frameRef != nil { setNeedsDisplay() }
        }
    }
    
    /// 上一次构建 frameRef 用的内容与范围
    private weak var lastFrameContent:NSAttributedString?
    
    private var lastFrameSize:CGSize?
    
    /// 按需构建 frameRef
    ///
    /// `pageModel.showContent` 在文字颜色没变时返回的是同一个实例，而滚动模式下 cell 复用
    /// 会把同一个 pageModel 反复赋进来。内容和范围都没变时可以直接复用已有的 CTFrame，
    /// 省掉一次整页 CoreText 排版（`CTFramesetterCreateWithAttributedString` + `CreateFrame`）。
    private func applyFrameRef(content:NSAttributedString?, size:CGSize) {
        
        if let frameRef = frameRef,
           let content = content,
           lastFrameContent === content,
           lastFrameSize == size {
            
            // CTFrame 可以复用，但 cell 复用后 readView 的 bounds 可能已经变了，
            // 必须显式重绘，否则屏幕上显示的是被拉伸的旧内容
            setNeedsDisplay()
            
            return
        }
        
        lastFrameContent = content
        
        lastFrameSize = size
        
        // 空内容也要能画（原来传 nil 会崩）
        frameRef = DZMCoreText.GetFrameRef(attrString: content ?? NSAttributedString(), rect: CGRect(origin: CGPoint.zero, size: size))
    }
    
    override init(frame: CGRect) {
        
        super.init(frame: frame)
        
        // 正常使用
        backgroundColor = UIColor.clear
        
        // 可以修改为随机颜色便于调试范围
//        backgroundColor = DZM_COLOR_ARC
    }
    
    /// 绘制
    override func draw(_ rect: CGRect) {
        
        if (frameRef == nil) {return}
        
        let ctx = UIGraphicsGetCurrentContext()
        
        ctx?.textMatrix = CGAffineTransform.identity
        
        ctx?.translateBy(x: 0, y: bounds.size.height);
        
        ctx?.scaleBy(x: 1.0, y: -1.0);
        
        CTFrameDraw(frameRef!, ctx!);
    }
    
    required init?(coder aDecoder: NSCoder) {
        
        fatalError("init(coder:) has not been implemented")
    }
}
