//
//  DZMReadViewStatusBottomView.swift
//  DZMeBookRead
//
//  Created by dengzemiao on 2019/4/17.
//  Copyright © 2019年 DZM. All rights reserved.
//

import UIKit

/// bottomView 高度
let DZM_READ_STATUS_BOTTOM_VIEW_HEIGHT:CGFloat =  DZM_SPACE_SA_30

class DZMReadViewStatusBottomView: UIView {
    
    /// 进度
    private(set) var progress:UILabel!
    
    /// 电池
    private var batteryView:DZMBatteryView!
    
    /// 时间
    private var timeLabel:UILabel!
    
    /// 计时器
    private var timer:Timer?
    
    override init(frame: CGRect) {
        
        super.init(frame: frame)
        
        addSubviews()
    }
    
    private func addSubviews() {
        
        // 电池
        batteryView = DZMBatteryView()
        batteryView.tintColor = DZMReadConfigure.shared().statusTextColor
        addSubview(batteryView)
        
        // 时间
        timeLabel = UILabel()
        timeLabel.textAlignment = .center
        timeLabel.font = DZM_FONT_SA_10
        timeLabel.textColor = DZMReadConfigure.shared().statusTextColor
        addSubview(timeLabel)
        
        // 进度
        progress = UILabel()
        progress.font = DZM_FONT_SA_10
        progress.textColor = DZMReadConfigure.shared().statusTextColor
        addSubview(progress)
        
        // 添加定时器（同时开启电量监测）
        addTimer()
        
        // 初始化调用。必须放在 addTimer() 之后：电量监测是在 addTimer() 里开启的，
        // 在此之前读 `batteryLevel` 只会拿到 -1，首次打开会显示一个空电量图标。
        didChangeTime()
    }
    
    override func layoutSubviews() {
        
        super.layoutSubviews()
        
        let w = frame.size.width
        let h = frame.size.height
    
        // 电池
        batteryView.frame.origin = CGPoint(x: w - DZMBatterySize.width, y: (h - DZMBatterySize.height) / 2)
        
        // 时间
        timeLabel.frame = CGRect(x: batteryView.frame.minX - DZM_SPACE_SA_50, y: 0, width: DZM_SPACE_SA_50, height: h)
        
        // 进度
        progress.frame = CGRect(x: 0, y: 0, width: DZM_SPACE_SA_50, height: h)
    }
    
    // MARK: -- 时间相关
    
    /// 添加定时器
    func addTimer() {
        
        if timer == nil {
            
            // Timer 会强引用 target。原先的 target/selector 写法与本视图构成保留环：
            // removeTimer() 只在 deinit 中调用，而 deinit 因保留环永不执行，
            // 于是每个状态栏视图都带着一个永不停止的定时器常驻内存。
            // 本视图在翻页/切章时会被反复新建，泄漏随阅读量线性累积。
            // 改用 block 版本并弱引用 self，让 deinit 能正常执行。
            timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
                self?.didChangeTime()
            }
            
            RunLoop.current.add(timer!, forMode: .common)
            
            // 仅在定时器存活期间开启电量监测
            DZMBatteryMonitoring.acquire()
        }
    }
    
    /// 删除定时器
    func removeTimer() {
        
        if timer != nil {
            
            timer!.invalidate()
            
            timer = nil
            
            DZMBatteryMonitoring.release()
        }
    }
    
    /// 视图离开窗口即停表
    ///
    /// 定时器由 RunLoop 持有，只有 invalidate 才会真正停止。视图被移出层级后已无显示
    /// 意义，这里主动停表，避免不可见的状态栏继续每 15 秒空转耗电。
    override func didMoveToWindow() {
        
        super.didMoveToWindow()
        
        if window == nil {
            
            removeTimer()
            
        }else{
            
            addTimer()
            
            // 重新进入窗口时立刻刷新一次，不必干等下一个 15 秒周期
            didChangeTime()
        }
    }
    
    /// 时间变化
    @objc func didChangeTime() {
        
        timeLabel.text = TimerString("HH:mm")
        
        batteryView.batteryLevel = UIDevice.current.batteryLevel
    }
    
    /// 销毁
    deinit {
        
        removeTimer()
    }
    
    required init?(coder aDecoder: NSCoder) {
        
        fatalError("init(coder:) has not been implemented")
    }
}

/// 电量监测的引用计数管理
///
/// `UIDevice.isBatteryMonitoringEnabled` 是进程级开关，一旦开启系统会持续监测电量变化。
/// 阅读器会在翻页/切章时反复创建状态栏视图，若在视图初始化里无条件开启且从不着手关闭，
/// 应用会在整个生命周期内保持电量监测。这里用引用计数保证：有视图需要时才开启，
/// 全部释放后立即关闭。
enum DZMBatteryMonitoring {
    
    private static var referenceCount = 0
    
    private static let lock = NSLock()
    
    /// 申请电量监测
    static func acquire() {
        
        lock.lock()
        
        referenceCount += 1
        
        let shouldEnable = (referenceCount == 1)
        
        lock.unlock()
        
        if shouldEnable { setEnabled(true) }
    }
    
    /// 释放电量监测
    static func release() {
        
        lock.lock()
        
        if referenceCount > 0 { referenceCount -= 1 }
        
        let shouldDisable = (referenceCount == 0)
        
        lock.unlock()
        
        if shouldDisable { setEnabled(false) }
    }
    
    private static func setEnabled(_ isEnabled: Bool) {
        
        if Thread.isMainThread {
            
            UIDevice.current.isBatteryMonitoringEnabled = isEnabled
            
        }else{
            
            DispatchQueue.main.async {
                
                UIDevice.current.isBatteryMonitoringEnabled = isEnabled
            }
        }
    }
}
