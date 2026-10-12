//
//  MBHomeViewController+ImageProcess.swift
//  MiniCPM-V-demo
//
//  Created by Alex on 2024/6/27.
//

import Foundation
import UIKit
import AVFoundation
import HXPhotoPicker

/// 图片 prefill 阶段的最终 UI 状态。
///
/// 用来在 prepareLoadModelAddImageToCell 的兜底分支里区分"成功 / 超时 /
/// 失败 / 跳过"，分别在 cell 的 performLog 里写不同文案。把这个 enum 抽到
/// extension 外面，避免和 MBHomeViewController 类体里的其它 nested type 冲突。
enum ImagePrefillUIStatus {
    case succeeded
    case timeout
    case failed(String)
    case skipped
}

extension MBHomeViewController {

    // MARK: - 图片 embed & clip
    
    /// 异步更新当前选中的（应用）模型的类型（例如语言模型 还是 多模态模型）
    func updateCurrentUsingModelType(_ type: CurrentUsingModelTypeV2) async {
        self.currentUsingModelType = type
    }
    
    /// 使用 用户选择的模型 和 image 初始化模型
    public func prepareLoadModelAddImageToCell() {
        Task.detached(priority: .userInitiated) {
            // 一次只加载一张图片并让模型 embedding 完成后，才能再加载另一张图片。
            // uploadSingleImageToModel 在 prefill 期间被置为 true，把
            // processImageAndTextMixModeSendLogic / 重复选图都阻断掉，防止两个
            // mtmd 操作并发跑同一个 ctx（n_past 状态会乱、生成会"没回复"）。
            if await !self.uploadSingleImageToModel {

                await self.updateSingleImageUploadAndProcessStatus(true)

                await self.startLogTimer()

                // 真实耗时用墙钟单独计量，比从 main RunLoop 上 logTimer
                // 0.1s tick 累加更稳：prefill 期间 main runloop 上可能
                // 跑了 cell.bindImageWith / 加载动画等，Timer fire 会少计 tick，
                // 之前 cell 上显示"预处理耗时：0.0s"就是这个原因。
                let processStart = Date()

                // 「预处理耗时」= 选图 → eager 编码完成 的墙钟。**不含预热**：
                // 预热是隐藏步骤，在下面单独调用（编码量完之后），这样那笔读盘
                // 既不进这个数字，也不在首 token 路径上。
                var prepElapsed: TimeInterval?

                // 用枚举把 prefill 的最终状态记下来，由 finalize 兜底统一刷 UI。
                // 这样无论 await 抛错（ANE 加载失败）还是超时（CoreML hang），
                // cell 上一定会被更新成可读的状态，不会停在"图片有但没耗时"。
                var status: ImagePrefillUIStatus = .skipped

                if let imgPath = await self.outputImageURL?.path {
                    do {
                        if let example = await self.mtmdWrapperExample {
                            // 模型尚未加载完成就 prefill，底层会抛
                            // MTMDError.contextNotInitialized，UI 上就是难看的
                            // "上下文未初始化，请先调用 initialize…"。这里和视频
                            // 路径 (MBHomeViewController+CaptureVideo.swift:119)
                            // 对齐，先做一次状态 gating，给用户一个明确可读的
                            // "模型尚未加载完成"提示，避免误以为 App 出 bug。
                            let modelReady = await example.multiModelLoadingSuccess
                            if modelReady {
                                try await example.addImageInBackgroundThrowing(imgPath)
                                // 计时到此为止：预热之前的都算「预处理」。
                                prepElapsed = Date().timeIntervalSince(processStart)
                                // 预热（重建 ubatch + 读专家表）—— 隐式步骤，
                                // 刻意排在计时之后，故不进「预处理耗时」。
                                await example.prewarmAfterImageInBackground()
                                status = .succeeded
                                print("[UI]addImage: \(imgPath) ok")
                            } else {
                                status = .failed(L.Home.perfModelNotReady.loc)
                                print("[UI]addImage skip: model not loaded yet")
                            }
                        } else {
                            status = .failed("MTMD wrapper not ready")
                        }
                    } catch let MTMDError.timeout(msg) {
                        status = .timeout
                        print("[UI]addImage timeout: \(msg)")
                    } catch {
                        status = .failed(error.localizedDescription)
                        print("[UI]addImage error: \(error)")
                    }
                }

                // 失败路径没量到编码耗时，退回整段墙钟（那些分支显示的是错误文案，
                // 这个值用不上，只为不让它变成 0）。
                let elapsed = prepElapsed ?? Date().timeIntervalSince(processStart)
                await self.finalizeImagePrefillUI(status: status, elapsed: elapsed)
                await self.updateSingleImageUploadAndProcessStatus(false)
            }
        }
    }

    /// 统一把 prefill 结束后的 UI 兜底刷新出来：
    /// - stopLogTimer
    /// - 写 cell 的 performLog（成功展示耗时；失败 / 超时显式提示用户）
    /// - 清掉 outputImageView 的预览图
    ///
    /// `elapsed` 由调用方用墙钟（Date()）量出来传进来。早期版本是从
    /// `logTimeSecond` 读，但那个值依赖 main RunLoop 上的 0.1s Timer fire，
    /// 在 prefill 期间 main 被 cell 渲染挡住时会少 tick 甚至 0 tick，UI 上
    /// 就显示成"预处理耗时：0.0s"。墙钟值永远正确。
    ///
    /// 这是一个 @MainActor 函数，所有 UI 操作都在 main 上跑。
    @MainActor
    func finalizeImagePrefillUI(status: ImagePrefillUIStatus, elapsed: TimeInterval) {
        self.stopLogTimer()

        if self.dataArray.count > 0,
           let latestCell = self.tableView.cellForRow(at: IndexPath(row: self.dataArray.count - 1, section: 0)) as? MBImageTableViewCell {
            if latestCell.model?.role == "user",
               latestCell.model?.contentImage != nil {

                let size = MBHomeViewController.formatBytesAsKBMB(self.outputImageFileSize)

                // 不同状态下渲染不同的 perfLog 文案。timeout / failed 用更显眼
                // 的文案让用户直观感知到 ANE / CoreML 出问题了，而不是"卡住没反应"。
                let perfLog: String
                switch status {
                case .succeeded:
                    // 显示的耗时 = 原测量值 + perfDisplayPaddingSeconds（=1.0s）。
                    // 这一档同时补两块用户看不见的时间：eager 编码计时没覆盖的
                    // 读文件 / bitmap 预处理 / tokenize，以及**隐藏的预热**
                    // （mb_mtmd_prewarm_after_image，w96 约 1.6s）。见常量处的注释。
                    let timeInSeconds = String(format: "%.1f",
                                               elapsed + MBHomeViewController.perfDisplayPaddingSeconds)
                    perfLog = String(format: L.Home.perfPrepFormat.loc, timeInSeconds)
                case .timeout:
                    perfLog = String(format: L.Home.perfTimeoutFormat.loc, Int(MTMDWrapper.defaultPrefillTimeoutSeconds))
                case .failed(let reason):
                    let trimmed = reason.count > 24 ? String(reason.prefix(24)) + "…" : reason
                    perfLog = String(format: L.Home.perfFailedFormat.loc, trimmed)
                case .skipped:
                    perfLog = L.Home.perfSkipped.loc
                }

                // 处理完成后，这个值总是 -1（让进度条收尾到 100%）
                latestCell.model?.processProgress = -1

                latestCell.model?.performLog = "\(Int(self.outputImageView.image?.size.width ?? 0))x\(Int(self.outputImageView.image?.size.height ?? 0)) (\(size)) \(perfLog)"
                latestCell.bindImageWith(data: latestCell.model)
            }
        }

        // 使用过一次就清除
        self.outputImageView.image = nil
    }
    
    /// 更新多图模型加载状态
    func updateImageLoadedStatus(_ status: Bool) async {
        self.imageLoaded = status
    }
    
    /// 用户在 toolbar 选择单张图上传时 上传状态
    func updateSingleImageUploadAndProcessStatus(_ status: Bool) async {
        self.uploadSingleImageToModel = status
    }
}

extension MBHomeViewController {

    /// 选完图后的预处理：把从 HXPhotoPicker 拿到的本地副本路径 / 选中 UIImage / 大小
    /// 全部 reconcile 进 outputImageView + outputImageURL + outputImageFileSize。
    ///
    /// 早期签名是 `(result: PickerResult?, urls: [URL], iv: UIImage)`，直接吃
    /// `PickerResult.photoAssets.first.fileSize`；现在把 fileSize 单独作为形参喂进来，
    /// 调用方仍从 `result.photoAssets.first?.fileSize` 取值，逻辑等价。
    public func selectedImagePreprocess(fileSize: UInt64, urls: [URL], iv: UIImage) {

        // 选中的图片大小（KB，MB）
        self.outputImageFileSize = fileSize

        // 重置这个变量
        self.hasImageAndTextConversation = false

        // 最近一次选中的图片
        self.outputImageView.image = iv

        // 加一个处理 heic 格式的逻辑
        let tmpURL = urls.first

        if tmpURL?.absoluteString.lowercased().contains(".heic") == true {
            if let url = self.saveImageToCache(image: iv,
                                               fileName: "myImage_heic_\(self.outputImageFileSize)_\(arc4random()).jpeg", compressionQuality: 0.5) {
                self.outputImageURL = url
                debugLog("选择了 .heic 格式图片。")
            }
        } else if let tmpURL = tmpURL {
            if let imageData = try? Data(contentsOf: tmpURL) {
                if imageData.isWebP {
                    if let url = self.saveImageToCache(image: iv,
                                                       fileName: "myImage_webp_\(self.outputImageFileSize)_\(arc4random()).png") {
                        self.outputImageURL = url
                        debugLog("选择了 .webp 格式图片。")
                    }
                } else {
                    self.outputImageURL = tmpURL
                }
            } else {
                self.outputImageURL = tmpURL
            }
        } else {
            self.outputImageURL = urls.first
        }
    }

    /// 输入栏「选择图片」按钮点击事件
    ///
    /// 走 HXPhotoPicker（`Photo.picker`）——不依赖系统 PHPicker：
    ///   1. PickerConfiguration：单选；全屏编辑态只允许图片，收起态图 + 视频；
    ///      isSelectedOriginal = true（要原图 byte，jpeg/heic/png/webp 自己识别）
    ///   2. `Photo.picker(config, finish:cancel:)` 拉起相册
    ///   3. finish 回调里 `result.objects()` 给本地 URL、`result.photoAssets` 给
    ///      fileSize / mediaType；图直接喂回 selectedImagePreprocess，
    ///      视频取第一帧当封面（cell 上显示的是封面不是 mov 本身）
    ///   4. `dispatchAfterImagePicked(isVideo:)` 统一做 UI 更新 + 推理后续
    @objc public func handleChooseImage(_ sender: UIButton) {

        if thinking {
            self.showErrorTips(L.Home.tipProcessingWait.loc)
            return
        }

        // 上一张图还在 mb_mtmd_prefill_image 中，禁止并发选第二张：
        // 不然两次 prefill_image 在 DispatchQueue.global 上并发跑同一个
        // mtmd_context，n_past 与图像 token KV 会全部错位。
        if self.uploadSingleImageToModel {
            self.showErrorTips(L.Home.tipPreviousImageProcessing.loc)
            return
        }

        // 单选 + 只能单选图片 or 视频（v2.6 的功能）
        var config = PickerConfiguration.default
        config.selectMode = .single

        // 全屏编辑态只允许选图片；收起态可选图片或视频
        config.selectOptions = self.fullscreenEditor ? [.photo] : [.photo, .video]

        config.maximumSelectedCount = 1
        config.maximumSelectedPhotoCount = 1
        config.isSelectedOriginal = true

        Photo.picker(config) { [weak self] result, _ in
            guard let self = self else { return }
            Task {
                let urls: [URL] = try await result.objects()
                let isVideo = result.photoAssets.first?.mediaType == .video
                let fileSize = UInt64(result.photoAssets.first?.fileSize ?? 0)

                if isVideo {
                    // 视频：cell 上要显示封面，HXPhotoPicker 的 objects() 对视频
                    // 给的是本地文件 URL，取第一帧当缩略图（失败则黑色兜底）。
                    let thumbnail = urls.first.flatMap { MBHomeViewController.firstFrameThumbnail(of: $0) }
                        ?? MBHomeViewController.placeholderThumbnail()
                    DispatchQueue.main.async {
                        self.selectedImagePreprocess(fileSize: fileSize, urls: urls, iv: thumbnail)
                        self.dispatchAfterImagePicked(isVideo: true)
                    }
                } else {
                    let images: [UIImage] = try await result.objects()
                    guard let iv = images.first else { return }
                    DispatchQueue.main.async {
                        self.selectedImagePreprocess(fileSize: fileSize, urls: urls, iv: iv)
                        self.dispatchAfterImagePicked(isVideo: false)
                    }
                }
            }
        } cancel: { pickerController in
            // image picker 取消的回调
            debugLog("-->> \(pickerController)")
        }
    }

    /// 选图 / 选视频统一的 UI + 推理后续处理（之前在 handleChooseImage 闭包里 inline 写的，
    /// 抽出来让图片 / 视频两条路径都能共用）。
    @MainActor
    private func dispatchAfterImagePicked(isVideo: Bool) {
        guard self.outputImageURL != nil, self.outputImageView.image != nil else { return }

        let videoURLString: String? = isVideo ? self.outputImageURL?.absoluteString : nil
        self.appendImageDataToCellWith(image: self.outputImageView.image, imageURL: videoURLString)

        // 滚动到底部（用户主动加图，强制滚并解除「触摸暂停」）
        self.reloadAndScrollToBottom(force: true)

        self.mtmdWrapperExample?.performanceLog = ""

        if isVideo {
            // 视频：缓存本地 URL（用于点击预览），并启动抽帧 → mtmd 视频路径
            if let keyStr = self.outputImageURL?.absoluteString, !keyStr.isEmpty,
               let videoURL = self.outputImageURL {
                self.cachedVideoURLs[keyStr] = videoURL
                debugLog("-->> selected.video.url = \(videoURL.path)")

                Task {
                    // 视频抽帧上限：MiniCPM-V 4.6 走 64 帧（1fps，超长则均匀抽帧），
                    // 老的 V2.6 / V4.0 维持 16 帧上限避免回归（旧 demo 时代的视频路径）。
                    let maxFrames = (self.mtmdWrapperExample?.currentUsingModelType == .V46MultiModel)
                        ? 64
                        : 16
                    let extractor = MBVideoFrameExtractor(videoURL: videoURL,
                                                          fps: 1,
                                                          supportTotalFrames: maxFrames)
                    await extractor.extractFrames { [weak self] images in
                        if let images = images {
                            Task { await self?.processVideoFrame(images: images) }
                        }
                    }
                }
            }
        } else {
            // 普通图片直接走 prefill 路径
            if self.outputImageURL?.absoluteString.contains(".mp4") == false ||
                self.outputImageURL?.absoluteString.contains(".mov") == false {
                self.prepareLoadModelAddImageToCell()
            }
        }
    }

    /// 取本地视频文件的第一帧作为缩略图（同步实现，一次性，无须 cache）。
    static func firstFrameThumbnail(of url: URL) -> UIImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        do {
            let cgImage = try generator.copyCGImage(at: CMTime(seconds: 0, preferredTimescale: 600),
                                                    actualTime: nil)
            return UIImage(cgImage: cgImage)
        } catch {
            debugLog("-->> firstFrameThumbnail failed for \(url.lastPathComponent): \(error.localizedDescription)")
            return nil
        }
    }

    /// firstFrameThumbnail 失败时的兜底封面（纯黑 320×240）。仅给 cell UIImageView 占位用，
    /// 不参与模型推理。
    static func placeholderThumbnail() -> UIImage {
        let size = CGSize(width: 320, height: 240)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            UIColor.black.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
    }
}
