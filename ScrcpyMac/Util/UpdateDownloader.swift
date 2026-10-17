//  UpdateDownloader.swift
//  ScrcpyMac
//

import CryptoKit
import Foundation

enum UpdateDownloadError: LocalizedError {
    case network(String)
    case http(Int)
    case saveFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .network(let detail):
            return detail.isEmpty ? "下载失败。" : "下载失败：\(detail)"
        case .http(let code):
            // 这一步最容易漏：URLSession 对 404 也会正常「下载」一个 HTML 错误页，
            // 不在这里拦住的话，失败会一路拖到校验和解压阶段才爆出来。
            return "下载失败：服务器返回 HTTP \(code)。"
        case .saveFailed(let detail):
            return "保存下载文件失败：\(detail)"
        case .cancelled:
            return "已取消。"
        }
    }
}

/// 带进度的文件下载器。
///
/// 引擎和 App 本体都要「下载一个 release 资产、报告进度、支持取消」，
/// 所以把 `URLSessionDownloadDelegate` 这一套收在一个地方。
/// 单独一个对象是为了避开 `URLSession` 强引用 delegate、delegate 又持有
/// session 造成的循环引用。
final class UpdateDownloader: NSObject, URLSessionDownloadDelegate {

    private let onProgress: (Double) -> Void
    private let onFinish: (Result<URL, Error>) -> Void

    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    /// `didCompleteWithError` 保证会被调用，而 `didFinishDownloadingTo` 不一定。
    /// 用它做唯一出口，保证回调只发一次。
    private var finished = false
    private var downloaded: URL?
    private var failure: Error?

    private var lastReported = 0.0

    init(progress: @escaping (Double) -> Void, completion: @escaping (Result<URL, Error>) -> Void) {
        self.onProgress = progress
        self.onFinish = completion
    }

    func start(request: URLRequest, configuration: URLSessionConfiguration) {
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        let task = session.downloadTask(with: request)
        self.task = task
        task.resume()
    }

    func cancel() {
        task?.cancel()
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let value = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        // 按 1% 粒度节流。每来一块数据就回一次主线程，会把主线程淹掉，
        // 而进度条根本分辨不出这 0.1% 的差别。
        guard value - lastReported >= 0.01 || value >= 1.0 else { return }
        lastReported = value
        onProgress(value)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // 这个方法一返回，系统就把 location 上的临时文件删了，所以必须在这里搬走。
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            failure = UpdateDownloadError.http(http.statusCode)
            return
        }

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("scrcpy-download-\(UUID().uuidString)")
            .appendingPathComponent(downloadTask.response?.suggestedFilename ?? "download")
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: location, to: destination)
            downloaded = destination
        } catch {
            failure = UpdateDownloadError.saveFailed(error.localizedDescription)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !finished else { return }
        finished = true
        session.finishTasksAndInvalidate()

        let result: Result<URL, Error>
        if let error {
            let code = (error as NSError).code
            // 用户主动取消不是故障，单独一个 case，免得弹一条吓人的错误。
            result = .failure(code == NSURLErrorCancelled
                              ? UpdateDownloadError.cancelled
                              : UpdateDownloadError.network(error.localizedDescription))
        } else if let failure {
            result = .failure(failure)
        } else if let downloaded {
            result = .success(downloaded)
        } else {
            result = .failure(UpdateDownloadError.network("下载结束但没有拿到文件。"))
        }
        onFinish(result)
    }
}

/// 流式算 SHA256，不把几十 MB 一次性读进内存。
enum FileDigest {

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            guard let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func isHex64(_ value: String) -> Bool {
        guard value.count == 64 else { return false }
        return value.allSatisfy { $0.isHexDigit }
    }
}
