//
//  DZMReadCatalogView.swift
//  DZMeBookRead
//
//  Created by dengzemiao on 2019/4/25.
//  Copyright © 2019年 DZM. All rights reserved.
//

import UIKit

@objc protocol DZMReadCatalogViewDelegate:NSObjectProtocol {
    
    /// 点击章节
    @objc optional func catalogViewClickChapter(catalogView:DZMReadCatalogView, chapterListModel:DZMReadChapterListModel)
}

class DZMReadCatalogView: UIView,UITableViewDelegate,UITableViewDataSource {

    /// 代理
    weak var delegate:DZMReadCatalogViewDelegate!
    
    /// 数据源
    var readModel:DZMReadModel! {
        
        didSet{
            
            // `scrollRecord()` 内部会按需刷新表，这里不再单独 reload 一次
            scrollRecord()
        }
    }

    var isChapterCached: ((Int) -> Bool)?
    
    private(set) var tableView:DZMTableView!
    
    override init(frame: CGRect) {
        
        super.init(frame: frame)
        
        addSubviews()
    }
    
    private func addSubviews() {
        
        tableView = DZMTableView()
        tableView.delegate = self
        tableView.dataSource = self
        addSubview(tableView)
    }
    
    /// 滚动到阅读记录
    func scrollRecord() {
        
        if readModel != nil {
            
            // 只在表内行数和数据源不一致时补一次整表 reload。
            //
            // 打开目录的路径是 `DZMReadLeftView.updateUI()`（已经刷新过）→ 这里，行数必然一致，
            // 再整表 reload 一次只会把已经布局好的 cell 全部丢弃重建，是纯浪费。
            // leftView 构造时走的是 `readModel` 的 didSet，那时表还是空的，行数不一致，
            // reload 照常发生 —— 两条路径都不会漏刷。
            let rowCount = readModel.chapterListModels.count
            
            if tableView.numberOfRows(inSection: 0) != rowCount {
                
                tableView.reloadData()
            }
       
            if !readModel.chapterListModels.isEmpty {
                
                var row = -1
                
                for (index, item) in readModel.chapterListModels.enumerated() {
                    
                    if (item.id == readModel.recordModel.chapterModel.id) {
                        
                        row = index
                        
                        break
                    }
                }
                
                if row != -1 {
                    
                    tableView.scrollToRow(at: IndexPath(row: row, section: 0), at: .middle, animated: false)
                }
            }
        }
    }
    
    override func layoutSubviews() {
        
        super.layoutSubviews()
        
        tableView.frame = bounds
    }
    
    // MARK: UITableViewDelegate,UITableViewDataSource
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        
        if readModel != nil { return readModel.chapterListModels.count }
        
        return 0
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        
        let cell = DZMReadCatalogCell.cell(tableView)
        
        // 章节
        let chapterListModel = readModel.chapterListModels[indexPath.row]
        
        // 章节名
        cell.chapterName.text = readModel.chapterListModels[indexPath.row].name
        cell.cachedMark.isHidden = !(isChapterCached?(indexPath.row) ?? false)
        
        // 日夜间
        if DZMUserDefaults.bool(DZM_READ_KEY_MODE_DAY_NIGHT) {
            
            cell.spaceLine.backgroundColor = DZM_COLOR_230_230_230.withAlphaComponent(0.1)
            
        }else{ cell.spaceLine.backgroundColor = DZM_COLOR_230_230_230 }
        
        // 阅读记录
        if readModel.recordModel.chapterModel.id == chapterListModel.id {
            
            cell.chapterName.textColor = DZM_READ_COLOR_MAIN
            
        }else{ cell.chapterName.textColor = DZM_COLOR_145_145_145 }
        
        return cell
    }
    
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        
        return DZM_SPACE_SA_50
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        
        delegate?.catalogViewClickChapter?(catalogView: self, chapterListModel: readModel.chapterListModels[indexPath.row])
    }
    
    required init?(coder aDecoder: NSCoder) {
        
        fatalError("init(coder:) has not been implemented")
    }
}
