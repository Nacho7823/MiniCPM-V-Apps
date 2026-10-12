//
//  MBV47ModelDownloadManager.swift
//  MiniCPM-V-demo
//
//  MiniCPM-V 4.7 的公网下载（35B-A3B MoE 43 个文件 / 1B 2 个文件）。
//
//  与其它下载器的区别：这两个模型是**多文件**的（MoE 的 experts/ 有 40 个分片），
//  所以这里按文件各起一个 MBModelDownloadHelperV2，并用一个小窗口控制并发
//  （43 个一起拉会把带宽和 Flash 都打满）。
//

import Foundation
import UIKit

/// 4.7 的两个变体。常量取值集中在 `MiniCPMV47Const` / `MiniCPMV47_1BConst`。
enum MBV47Variant {
    case moe
    case oneB

    var displayedName: String {
        switch self {
        case .moe:  return MiniCPMV47Const.displayedName
        case .oneB: return MiniCPMV47_1BConst.displayedName
        }
    }

    var documentsDirName: String {
        switch self {
        case .moe:  return MiniCPMV47Const.documentsDirName
        case .oneB: return MiniCPMV47_1BConst.documentsDirName
        }
    }

    var userDefaultsKey: String {
        switch self {
        case .moe:  return MiniCPMV47Const.userDefaultsKey
        case .oneB: return MiniCPMV47_1BConst.userDefaultsKey
        }
    }

    var hfBase: String {
        switch self {
        case .moe:  return MiniCPMV47Const.hfBase
        case .oneB: return MiniCPMV47_1BConst.hfBase
        }
    }

    var msBase: String {
        switch self {
        case .moe:  return MiniCPMV47Const.msBase
        case .oneB: return MiniCPMV47_1BConst.msBase
        }
    }

    var files: [ModelDownloadFile] {
        switch self {
        case .moe:  return MiniCPMV47Const.downloadFiles
        case .oneB: return MiniCPMV47_1BConst.downloadFiles
        }
    }

    var modelType: CurrentUsingModelTypeV2 {
        switch self {
        case .moe:  return .V47MoE
        case .oneB: return .V47_1B
        }
    }
}

final class MBV47ModelDownloadManager: NSObject {

    static let moe = MBV47ModelDownloadManager(variant: .moe)
    static let oneB = MBV47ModelDownloadManager(variant: .oneB)

    let variant: MBV47Variant

    /// 同时在传的文件数。43 个一起拉会把带宽打满、也拖慢单文件，
    /// 反而让「先出来」的那个大文件迟迟不完。
    private let maxConcurrent = 3

    private var wrapper: MTMDWrapperExample?
    private let queue = DispatchQueue(label: "com.minicpm.v47.download")

    private init(variant: MBV47Variant) {
        self.variant = variant
        super.init()
    }

    // MARK: - 状态

    /// localName -> helper（懒建，只建一次）
    private var helpers: [String: MBModelDownloadHelperV2] = [:]
    /// localName -> 0...1
    private var fileProgress: [String: CGFloat] = [:]
    private var fileState: [String: DownloadStatus] = [:]
    private var inFlight: Set<String> = []
    private var startTimes: [String: Date] = [:]

    var detailedProgressHandler: ((DownloadProgressInfo) -> Void)?
    var completionHandler: ((String, Bool) -> Void)?

    // MARK: - 路径

    private func documentsDir() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// 该文件应落在哪儿（`Documents/<documentsDirName>/<localName>`）。
    func localURL(for file: ModelDownloadFile) -> URL {
        documentsDir()
            .appendingPathComponent(variant.documentsDirName)
            .appendingPathComponent(file.localName)
    }

    // MARK: - 装配

    func setupDownloadManager(with wrapper: MTMDWrapperExample) {
        self.wrapper = wrapper
        for f in variant.files {
            _ = helper(for: f)
        }
        reconcileStatusFromDisk()
        restoreDownloadProgress()
    }

    private func helper(for file: ModelDownloadFile) -> MBModelDownloadHelperV2? {
        if let h = queue.sync(execute: { helpers[file.localName] }) { return h }
        guard let wrapper = wrapper ?? sharedWrapperProbe else { return nil }
        let h = MBModelDownloadHelperV2(
            wrapper: wrapper,
            modelName: variant.displayedName,
            modelUrl: "\(variant.hfBase)/\(file.remotePath)",
            filename: fullLocalName(file),
            backupModelUrl: "\(variant.msBase)/\(file.remotePath)"
        )
        queue.sync { helpers[file.localName] = h }
        return h
    }

    /// `setupDownloadManager` 之前的兜底：详情页一定会先调 setup，
    /// 这里只是防止极端时序下拿到 nil。
    private var sharedWrapperProbe: MTMDWrapperExample? { MBV47WrapperHolder.shared }

    /// helper 的 `filename` 必须带上模型子目录，否则会平铺到 Documents 根。
    private func fullLocalName(_ file: ModelDownloadFile) -> String {
        "\(variant.documentsDirName)/\(file.localName)"
    }

    // MARK: - 状态查询

    func isFileDownloaded(_ file: ModelDownloadFile) -> Bool {
        FileManager.default.fileExists(atPath: localURL(for: file).path)
    }

    func fileStatus(_ file: ModelDownloadFile) -> String {
        if isFileDownloaded(file) { return "downloaded" }
        return (queue.sync { fileState[file.localName] }) == .failed ? "failed" : "download"
    }

    func allFilesDownloaded() -> Bool {
        variant.files.allSatisfy { isFileDownloaded($0) }
    }

    func hasAnyDownloadActive() -> Bool {
        !queue.sync { inFlight }.isEmpty
    }

    /// 已下载的字节 / 总字节（用常量里的期望尺寸当分母，不必等 HEAD）。
    func overallProgress() -> CGFloat {
        let files = variant.files
        let total = files.reduce(Int64(0)) { $0 + $1.bytes }
        guard total > 0 else { return 0 }
        var done: Double = 0
        let prog = queue.sync { fileProgress }
        for f in files {
            if isFileDownloaded(f) {
                done += Double(f.bytes)
            } else {
                done += Double(f.bytes) * Double(prog[f.localName] ?? 0)
            }
        }
        return CGFloat(min(1.0, done / Double(total)))
    }

    func downloadedBytes() -> Int64 {
        let files = variant.files
        let total = files.reduce(Int64(0)) { $0 + $1.bytes }
        return Int64(Double(total) * Double(overallProgress()))
    }

    func totalBytes() -> Int64 {
        variant.files.reduce(Int64(0)) { $0 + $1.bytes }
    }

    // MARK: - 与磁盘对账

    func reconcileStatusFromDisk() {
        for f in variant.files {
            let ok = isFileDownloaded(f)
            queue.sync {
                fileState[f.localName] = ok ? .completed : .notStarted
                if ok { fileProgress[f.localName] = 1.0 }
            }
        }
    }

    /// App 被杀后重进：FDownLoader 里还留着「下载中」的缓存条目，接着跑。
    private func restoreDownloadProgress() {
        let info = FDownLoaderManager.shareInstance().downLoaderInfo
        guard let info = info, info.count > 0 else { return }
        var resumed = false
        for f in variant.files where !isFileDownloaded(f) {
            guard let h = helper(for: f),
                  let key = String(stringLiteral: h.modelUrl).md5() as String?,
                  let obj = info[key] as? FDownLoader,
                  obj.state == .downLoading else { continue }
            resumed = true
            break
        }
        if resumed {
            debugLog("-->> V47(\(variant.documentsDirName)) 检测到未完成下载，自动续传")
            downloadAll()
        }
    }

    // MARK: - 下载

    func downloadAll() {
        reconcileStatusFromDisk()
        let pending = variant.files.filter { !isFileDownloaded($0) }
        debugLog("-->> V47(\(variant.documentsDirName)) 待下载 \(pending.count) 个文件，"
                 + "窗口 \(maxConcurrent)")

        for f in pending {
            queue.sync { fileState[f.localName] = .notStarted }
        }
        pump()
    }

    /// 用「完成一个补一个」的窗口调度，替代一次性全部并发。
    private func pump() {
        // 注意：不要在 filter 里写 `queue.sync { ... $0 ... }` —— 内层闭包的 `$0`
        // 会遮蔽外层元素，编译期报 "expects 0 arguments"。显式取名字。
        let pending = variant.files.filter { f in
            if isFileDownloaded(f) { return false }
            if queue.sync(execute: { inFlight.contains(f.localName) }) { return false }
            if queue.sync(execute: { fileState[f.localName] == .failed }) { return false }
            return true
        }
        let free = maxConcurrent - queue.sync { inFlight.count }
        guard free > 0, !pending.isEmpty else {
            if !hasAnyDownloadActive() { finishIfComplete() }
            return
        }
        for f in pending.prefix(free) {
            start(f)
        }
    }

    private func start(_ file: ModelDownloadFile) {
        guard let h = helper(for: file) else { return }
        queue.sync {
            inFlight.insert(file.localName)
            fileState[file.localName] = .downloading
            startTimes[file.localName] = Date()
            fileProgress[file.localName] = 0
        }

        h.downloadV2(completionBlock: { [weak self] status, progress in
            guard let self = self else { return }
            DispatchQueue.main.async {
                if progress >= 1 {
                    self.queue.sync {
                        self.fileProgress[file.localName] = 1.0
                        self.fileState[file.localName] = .completed
                        self.inFlight.remove(file.localName)
                    }
                    self.report(file)
                    self.pump()
                } else if status == "failed" {
                    self.queue.sync {
                        self.fileState[file.localName] = .failed
                        self.inFlight.remove(file.localName)
                    }
                    self.report(file)
                    self.pump()
                } else {
                    self.queue.sync { self.fileProgress[file.localName] = progress }
                    self.report(file)
                }
            }
        })
    }

    private func report(_ file: ModelDownloadFile) {
        var speed: Double = 0
        let st = queue.sync { startTimes[file.localName] }
        if let st = st {
            let el = Date().timeIntervalSince(st)
            let p = queue.sync { fileProgress[file.localName] } ?? 0
            if el > 0, p > 0 {
                speed = Double(file.bytes) * Double(p) / el
            }
        }
        let info = DownloadProgressInfo(
            modelName: file.localName,
            status: queue.sync { fileState[file.localName] } ?? .notStarted,
            progress: queue.sync { fileProgress[file.localName] } ?? 0,
            downloadedBytes: Int64(Double(file.bytes) * Double(queue.sync { fileProgress[file.localName] } ?? 0)),
            totalBytes: file.bytes,
            speed: speed,
            estimatedTimeRemaining: speed > 0
                ? Double(file.bytes) * (1 - Double(queue.sync { fileProgress[file.localName] } ?? 0)) / speed
                : 0
        )
        detailedProgressHandler?(info)
    }

    /// 全部文件到齐后做一次整体校验（MoE 用 manifest 逐层验字节数）。
    private func finishIfComplete() {
        guard allFilesDownloaded() else {
            completionHandler?(variant.displayedName, false)
            return
        }
        if case .moe = variant {
            let expertsURL = documentsDir()
                .appendingPathComponent(variant.documentsDirName)
                .appendingPathComponent(MiniCPMV47Const.expertsDirName)
            let problems = MiniCPMV47Const.expertsProblems(at: expertsURL)
            guard problems.isEmpty else {
                debugLog("-->> V47 experts 校验失败 \(problems.count) 个文件，判定下载失败")
                completionHandler?(variant.displayedName, false)
                return
            }
        }
        completionHandler?(variant.displayedName, true)
    }

    // MARK: - 删除 / 重置

    func deleteAllDownloadedFiles() {
        let fm = FileManager.default
        for f in variant.files {
            let url = localURL(for: f)
            if fm.fileExists(atPath: url.path) { try? fm.removeItem(at: url) }
        }
        // experts 目录本身也清掉，避免留个空壳让 resolveArtifacts 误判
        if case .moe = variant {
            let dir = documentsDir()
                .appendingPathComponent(variant.documentsDirName)
                .appendingPathComponent(MiniCPMV47Const.expertsDirName)
            try? fm.removeItem(at: dir)
        }
        resetDownloadStates()
        reconcileStatusFromDisk()
    }

    func resetDownloadStates() {
        queue.sync {
            fileState.removeAll()
            fileProgress.removeAll()
            inFlight.removeAll()
            startTimes.removeAll()
        }
        for (_, h) in queue.sync(execute: { helpers }) {
            h.status = "download"
        }
    }

    func cancelAllDownloads() {
        FDownLoaderManager.shareInstance().downLoaderInfo.removeAllObjects()
        resetDownloadStates()
    }

    var mainModelManager: MBModelDownloadHelperV2? {
        guard let f = variant.files.first(where: { $0.localName.hasSuffix(".gguf") && !$0.localName.contains("/") })
        else { return nil }
        return helper(for: f)
    }
}

/// 详情页 push 之前 manager 可能还没拿到 wrapper；用一个极小的持有者兜底。
final class MBV47WrapperHolder {
    static var shared: MTMDWrapperExample?
}
