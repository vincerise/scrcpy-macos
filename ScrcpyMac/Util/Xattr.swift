//  Xattr.swift
//  Scrcpy
//

import Darwin
import Foundation

/// 递归清除 macOS 给外来二进制打的隔离/来源属性。
///
/// 为什么必须做：App 要 exec 的是自己下载或拷贝进来的 `scrcpy` 与 `adb`。
/// 带着 `com.apple.quarantine` 的嵌套二进制会被 Gatekeeper 单独评估，用户看到的是
/// 「无法验证开发者」——而命令行子进程几乎没有靠谱的「仍要打开」路径，等于直接不可用。
/// 清零的成本可以忽略，所以只要引擎文件换过地方就统一做一次。
///
/// `com.apple.provenance` 是新系统给「来自其他 App / 网络」的文件打的来源标记，
/// 同样会让子进程首次执行时被拦一下，一并清掉。
///
/// 刻意用 Darwin 的 `removexattr` 而不是 shell 出去跑 `xattr -cr`：
/// 走系统调用没有引号转义、路径编码和被污染的 PATH 这些问题，也不用为它做超时保护。
enum Xattr {

    /// 需要清除的属性名。
    private static let names = ["com.apple.quarantine", "com.apple.provenance"]

    /// 递归清除 `url` 自身及其所有后代的隔离属性，返回处理过的路径数。
    ///
    /// 返回的是**走过的路径数**，不区分该路径上是否真的挂着这些属性 ——
    /// 「本来就没有属性」是最常见的正常情况，把它算作失败没有意义。
    @discardableResult
    static func strip(_ url: URL) -> Int {
        var processed = 0
        let fm = FileManager.default

        // 根自身也要清：目录自己带 quarantine 时，打开它读内容的进程同样会被评估。
        stripOne(url)
        processed += 1

        // 不跳过隐藏文件：隐藏目录里也可能有会被 exec 的东西，
        // 而这一步的代价只是几十次 syscall。
        guard let walker = fm.enumerator(at: url,
                                         includingPropertiesForKeys: nil,
                                         options: [],
                                         errorHandler: { _, _ in true }) else {
            return processed
        }
        for case let child as URL in walker {
            stripOne(child)
            processed += 1
        }
        return processed
    }

    /// 清掉单个路径上的两个属性。属性不存在时 `removexattr` 返回 -1/ENOATTR，
    /// 这是常态而非错误，所以返回值直接丢弃。
    private static func stripOne(_ url: URL) {
        url.withUnsafeFileSystemRepresentation { raw in
            // 用 fileSystemRepresentation 而不是 url.path：macOS 文件名存在
            // NFC/NFD 两种归一化形式，拿 Swift 的 String 直接进 syscall 有对不上的风险。
            guard let raw else { return }
            for name in names {
                _ = removexattr(raw, name, 0)
            }
        }
    }
}
