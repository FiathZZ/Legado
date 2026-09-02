//
//  DZMReadViewScrollController.swift
//  DZMeBookRead
//
//  Created by dengzemiao on 2019/4/17.
//  Copyright © 2019年 DZM. All rights reserved.
//

import UIKit

class DZMReadViewScrollController: DZMViewController,UITableViewDelegate,UITableViewDataSource {

    /// 当前主控制器
    weak var vc:DZMReadController!
    
    /// 顶部状态栏
    private var topView:DZMReadViewStatusTopView!
    
    /// 阅读视图
    private var tableView:DZMTableView!
    
    /// 底部状态栏
    private var bottomView:DZMReadViewStatusBottomView!
    
    /// 当前阅读章节ID列表(只会存放本次阅读的列表)
    private var chapterIDs:[NSNumber] = []
    
    /// 当前正在加载的章节
    private var loadChapterIDs:[NSNumber] = []
    
    /// 当前阅读的章节列表,通过已有的章节ID列表,来获取章节模型。
    private var chapterModels:[String:DZMReadChapterModel] = [:]
    
    /// 记录滚动坐标
    private var scrollPoint:CGPoint!
    
    /// 是否为向上滚动
    private var isScrollUp:Bool = true

    /// Keep the native record current during a long continuous scroll without updating it for
    /// every pixel of movement.
    private var scheduledProgressUpdate: DispatchWorkItem?
    
    override func viewDidLoad() {
        
        super.viewDidLoad()
        
        // 阅读记录开始阅读
        chapterIDs.append(vc.readModel.recordModel.chapterModel.id)
        
        // 刷新阅读进度
        reloadProgress()

        // Start preparing the following chapter as soon as the reader opens. Relying only on
        // `willDisplayHeaderView` is too late/unreliable for the 0.01-point section header and can
        // leave the user waiting at the chapter boundary.
        preloadingNext(vc.readModel.recordModel.chapterModel, depth: 1)
        
        // 定位上次阅读位置
        tableView.scrollToRow(at: IndexPath(row: vc.readModel.recordModel.page.intValue, section: 0), at: .top, animated: false)
    }
    
    override func addSubviews() {
        
        super.addSubviews()
        
        // 阅读使用范围
        let readRect = DZM_READ_RECT!
        
        // 顶部状态栏
        topView = DZMReadViewStatusTopView()
        topView.bookName.text = vc.readModel.bookName
        topView.chapterName.text = vc.readModel.recordModel.chapterModel.name
        view.addSubview(topView)
        topView.frame = CGRect(x: readRect.minX, y: readRect.minY, width: readRect.width, height: DZM_READ_STATUS_TOP_VIEW_HEIGHT)
        topView.isHidden = true
        
        // 阅读视图
        tableView = DZMTableView()
        tableView.delegate = self
        tableView.dataSource = self
        tableView.showsVerticalScrollIndicator = false
        tableView.showsHorizontalScrollIndicator = false
        // A status-bar tap must not move the reader to page one and overwrite the saved position.
        tableView.scrollsToTop = false
        tableView.separatorStyle = .none
        view.addSubview(tableView)
        tableView.frame = DZM_READ_VIEW_RECT
        
        // 底部状态栏
        bottomView = DZMReadViewStatusBottomView()
        view.addSubview(bottomView)
        bottomView.frame = CGRect(x: readRect.minX, y: readRect.maxY - DZM_READ_STATUS_BOTTOM_VIEW_HEIGHT, width: readRect.width, height: DZM_READ_STATUS_BOTTOM_VIEW_HEIGHT)
        bottomView.isHidden = true
    }
    
    // MARK: UITableViewDelegate,UITableViewDataSource
    
    func numberOfSections(in tableView: UITableView) -> Int {
        
        return chapterIDs.count
    }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        
        let chapterID = chapterIDs[section]
        
        // 获取章节内容模型
        let chapterModel = GetChapterModel(chapterID: chapterID)
        
        // 有数据则返回页数
        if chapterModel != nil { return chapterModel!.pageCount.intValue }
        
        // 没有数据或者正在加载
        return 0
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        
        let chapterID = chapterIDs[indexPath.section]
        
        let chapterModel = GetChapterModel(chapterID: chapterID)
        
        let pageModel = chapterModel!.pageModels[indexPath.row]
        
        // 是否为书籍首页
        if pageModel.isHomePage {
            
            let cell = DZMReadHomeViewCell.cell(tableView)
            
            cell.homeView.readModel = vc.readModel
            
            return cell
            
        }else{
            
            let cell = DZMReadViewCell.cell(tableView)
            
            cell.pageModel = pageModel
            
            return cell
        }
    }
    
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        
        let chapterID = chapterIDs[indexPath.section]
        
        let chapterModel = GetChapterModel(chapterID: chapterID)
        
        return chapterModel!.pageModels[indexPath.row].cellHeight
    }
    
    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        
        return DZM_SPACE_MIN_HEIGHT
    }
    
    func tableView(_ tableView: UITableView, willDisplayHeaderView view: UIView, forSection section: Int) {
        
        let chapterModel = chapterModels[chapterIDs[section].stringValue]
        
        // 预加载上一章
        preloadingPrevious(chapterModel)
        
        // 预加载下一章
        preloadingNext(chapterModel, depth: 1)
    }
    
    /// 书籍首页将要出现
    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        
        if indexPath.row != 0 { return }
        
        let chapterID = chapterIDs[indexPath.section]
        
        let chapterModel = GetChapterModel(chapterID: chapterID)
        
        let pageModel = chapterModel!.pageModels[indexPath.row]
        
        if pageModel.isHomePage {
            
            topView?.isHidden = true
            
            bottomView?.isHidden = true
        }
    }
    
    /// 书籍首页消失
    func tableView(_ tableView: UITableView, didEndDisplaying cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        
        if indexPath.row != 0 { return }
        
        let chapterID = chapterIDs[indexPath.section]
        
        let chapterModel = GetChapterModel(chapterID: chapterID)
        
        let pageModel = chapterModel!.pageModels[indexPath.row]
        
        if pageModel.isHomePage {
            
            topView?.isHidden = false
            
            bottomView?.isHidden = false
        }
    }
    
    
    // MARK: 监控滚动以及拖拽
    
    // 开始拖拽
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
 
        // 隐藏菜单
        vc.readMenu.showMenu(isShow: false)
        
        // 重置属性
        isScrollUp = true
        scrollPoint = CGPoint.zero
    }
    
    // 结束拖拽
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        updateReadRecordImmediately()
    }
    
    // 开始减速
    func scrollViewWillBeginDecelerating(_ scrollView: UIScrollView) {
        updateReadRecordImmediately()
    }
    
    // 结束减速
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        updateReadRecordImmediately()
    }
    
    // 正在滚动
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        
        if scrollPoint == nil { return }
        
        let point = scrollView.panGestureRecognizer.translation(in: scrollView)
        
        if point.y < scrollPoint.y { // 上滚
            
            isScrollUp = true
            
        }else if point.y > scrollPoint.y { // 下滚
            
            isScrollUp = false
            
        }else{ }
        
        // 记录坐标
        scrollPoint = point
        scheduleProgressUpdate()
    }

    private func scheduleProgressUpdate() {
        guard scheduledProgressUpdate == nil else { return }

        let update = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.scheduledProgressUpdate = nil
            self.updateReadRecord(isRollingUp: self.isScrollUp)
        }
        scheduledProgressUpdate = update
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: update)
    }

    private func updateReadRecordImmediately() {
        scheduledProgressUpdate?.cancel()
        scheduledProgressUpdate = nil
        updateReadRecord(isRollingUp: isScrollUp)
    }

    /// Called before the process is suspended, when a delayed scroll update is not sufficient.
    func updateReadRecordForLifecycle() {
        updateReadRecordImmediately()
        vc.readModel.recordModel.save()
    }
    
    // MARK: 阅读记录以及进度
    
    /// 更新阅读记录(滚动模式) isRollingUp:是否为往上滚动
    private func updateReadRecord(isRollingUp:Bool) {
        let indexPaths = tableView.indexPathsForVisibleRows
        guard let indexPaths, !indexPaths.isEmpty else { return }

        let indexPath = isRollingUp ? indexPaths[indexPaths.count - 1] : indexPaths[0]
        guard chapterIDs.indices.contains(indexPath.section),
              let chapterModel = GetChapterModel(chapterID: chapterIDs[indexPath.section]) else {
            return
        }

        // Archiving a DZM record serializes the complete chapter text and every CoreText page.
        // Doing that from scroll/deceleration callbacks blocks the UI exactly at chapter
        // boundaries. Keep the native record current in memory; lifecycle persistence above and
        // ReaderProgressSaveCoordinator own the durable writes.
        vc.readModel.recordModel.modify(
            chapterModel: chapterModel,
            page: indexPath.row,
            isSave: false
        )
        DZM_READ_RECORD_CURRENT_CHAPTER_LOCATION = vc.readModel.recordModel.locationFirst
        topView.chapterName.text = chapterModel.name
        reloadProgress()

        if isRollingUp {
            preloadingNext(chapterModel)
        } else {
            preloadingPrevious(chapterModel)
        }
        vc.scrollReadingPositionDidChange()
    }
    
    /// 刷新阅读进度显示
    private func reloadProgress() {
        
        if DZMReadConfigure.shared().progressType == .total { // 总进度
            
            // 当前阅读进度
            let progress:Float = DZM_READ_TOTAL_PROGRESS(readModel: vc.readModel, recordModel: vc.readModel.recordModel)
            
            // 显示进度
            bottomView.progress.text = DZM_READ_TOTAL_PROGRESS_STRING(progress: progress)
            
            
        }else{ // 分页进度
            
            // 显示进度
            bottomView.progress.text = "\(vc.readModel.recordModel.page.intValue + 1)/\(vc.readModel.recordModel.chapterModel!.pageCount.intValue)"
        }
    }
    
    // MARK: 获得阅读数据
    
    /// 获取章节内容模型
    private func GetChapterModel(chapterID:NSNumber) ->DZMReadChapterModel? {
        
        var chapterModel:DZMReadChapterModel? = nil
        
        if chapterModels.keys.contains(chapterID.stringValue) { // 内存中存在章节内容
            
            chapterModel = chapterModels[chapterID.stringValue]
            
        }else{ // 内存中不存在章节列表
            
            // 检查是否存在章节内容
            let isExist = DZMReadChapterModel.isExist(bookID: vc.readModel.bookID, chapterID: chapterID)
            
            // 存在 || 不存在(但是为本地阅读)
            if isExist || vc.readModel.bookSourceType == .local {
                
                // 获取章节数据
                if !isExist {
                    
                    chapterModel = DZMReadTextFastParser.parser(readModel: vc.readModel, chapterID: chapterID)
                    
                }else{
                    
                    chapterModel = DZMReadChapterModel.model(bookID: vc.readModel.bookID, chapterID: chapterID)
                }
                
                chapterModels[chapterID.stringValue] = chapterModel
            }
        }
        
        return chapterModel
    }
    
    
    // MARK: 预加载数据
    
    /// 预加载上一个章节
    private func preloadingPrevious(_ chapterModel:DZMReadChapterModel!) {
        guard let chapterModel,
              let chapterID = chapterModel.previousChapterID,
              !chapterModel.isFirstChapter,
              !loadChapterIDs.contains(chapterID),
              !chapterIDs.contains(chapterID) else { return }

        loadChapterIDs.append(chapterID)
        let anchorChapterID = chapterModel.id!

        loadAdjacentChapter(chapterID) { [weak self] tempChapterModel in
            guard let self,
                  let tempChapterModel,
                  let currentIndex = self.chapterIDs.index(of: anchorChapterID) else {
                self?.finishLoading(chapterID)
                return
            }

            let previousIndex = max(0, currentIndex - 1)
            self.chapterModels[chapterID.stringValue] = tempChapterModel
            self.chapterIDs.insert(chapterID, at: previousIndex)
            self.finishLoading(chapterID)
            UIView.performWithoutAnimation {
                self.tableView.insertSections(IndexSet(integer: previousIndex), with: .none)
            }
            self.tableView.contentOffset = CGPoint(
                x: 0,
                y: self.tableView.contentOffset.y + tempChapterModel.pageTotalHeight
            )
        }
    }
    
    /// 预加载下一个章节
    /// Preloads a small bounded window so a fast continuous scroll does not catch the reader at
    /// the first uncached chapter boundary. `depth` counts additional chapters after this one.
    private func preloadingNext(_ chapterModel:DZMReadChapterModel!, depth: Int = 1) {
        guard let chapterModel,
              let chapterID = chapterModel.nextChapterID,
              !chapterModel.isLastChapter,
              !loadChapterIDs.contains(chapterID),
              !chapterIDs.contains(chapterID) else { return }

        loadChapterIDs.append(chapterID)
        let anchorChapterID = chapterModel.id!

        loadAdjacentChapter(chapterID) { [weak self] tempChapterModel in
            guard let self,
                  let tempChapterModel,
                  let currentIndex = self.chapterIDs.index(of: anchorChapterID) else {
                self?.finishLoading(chapterID)
                return
            }

            let nextIndex = currentIndex + 1
            self.chapterModels[chapterID.stringValue] = tempChapterModel
            self.chapterIDs.insert(chapterID, at: nextIndex)
            self.finishLoading(chapterID)
            // The new section is below the current viewport. Inserting only that section avoids
            // rebuilding every visible cell while the user is crossing the chapter boundary.
            UIView.performWithoutAnimation {
                self.tableView.insertSections(IndexSet(integer: nextIndex), with: .none)
            }

            if depth > 0 {
                self.preloadingNext(tempChapterModel, depth: depth - 1)
            }
        }
    }

    private func loadAdjacentChapter(
        _ chapterID: NSNumber,
        completion: @escaping (DZMReadChapterModel?) -> Void
    ) {
        let readModel = vc.readModel!
        let bookID = readModel.bookID!
        let isPersisted = DZMReadChapterModel.isExist(bookID: bookID, chapterID: chapterID)

        DZMAdjacentChapterRequest.request(
            isPersisted: isPersisted,
            sourceType: readModel.bookSourceType,
            loadPersistedOrLocal: { [weak readModel] in
                guard let readModel else { return nil }
                if isPersisted {
                    return DZMReadChapterModel.model(bookID: bookID, chapterID: chapterID)
                }
                return DZMReadTextFastParser.parser(readModel: readModel, chapterID: chapterID)
            },
            loadRemote: { completion in
                guard let loader = readModel.loadChapterModel else {
                    completion(nil)
                    return
                }
                loader(chapterID, completion)
            }
        ) { [weak self] chapterModel in
            DispatchQueue.main.async {
                guard let self else { return }
                guard chapterModel != nil else {
                    self.finishLoading(chapterID)
                    return
                }
                completion(chapterModel)
            }
        }
    }

    private func finishLoading(_ chapterID: NSNumber) {
        guard let loadIndex = loadChapterIDs.index(of: chapterID) else { return }
        loadChapterIDs.remove(at: loadIndex)
    }
}
