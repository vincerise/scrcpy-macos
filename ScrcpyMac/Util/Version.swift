//  Version.swift
//  ScrcpyMac
//

import Foundation

/// 版本号比较与发布版本格式校验。
///
/// 引擎和 App 本体各有一套更新流程，但「谁更新」这件事必须用同一套规则判断，
/// 否则两个更新器会对同一个版本号给出不同答案。
enum Version {

    /// 语义化比较，逐段按整数比。
    static func isNewer(_ a: String, than b: String) -> Bool {
        let lhs = numericSegments(a)
        let rhs = numericSegments(b)
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left > right }
        }
        return false
    }

    /// `v0.2.0`、`0.2` 这类发布版本号。
    ///
    /// 比 `isNewer` 严格：release tag 是我们自己控制的，不该接受
    /// `5.1.0-rc1` 这种后缀——解析不了的后缀会被当成 0，悄悄比出一个错误结果。
    static func isReleaseVersion(_ value: String) -> Bool {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count) else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy(\.isNumber)
        }
    }

    /// 新版本要求的最低系统版本（`LSMinimumSystemVersion`）是否满足。
    ///
    /// 取不到或格式不认识时按「满足」处理：这里返回 false 会让一次正常的更新
    /// 被拒绝，而缺失这个键本身不是安全信号。
    static func isAtLeastOS(_ requirement: String?) -> Bool {
        guard let requirement, isReleaseVersion(requirement) else { return true }
        let needed = numericSegments(requirement)
        let running = ProcessInfo.processInfo.operatingSystemVersion
        let current = [running.majorVersion, running.minorVersion, running.patchVersion]
        for index in 0..<max(needed.count, current.count) {
            let want = index < needed.count ? needed[index] : 0
            let have = index < current.count ? current[index] : 0
            if want != have { return have > want }
        }
        return true
    }

    private static func numericSegments(_ version: String) -> [Int] {
        var text = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        // 必须逐段转整数再比。按字符串比的话 "5.0.10" < "5.0.9"，
        // 而 scrcpy 确实走到过 5.0.10 这种段号。
        return text.split(separator: ".").map { field in
            // 段里可能混着预发布后缀（"5.1.0-rc1"），取数字前缀；取不到当 0。
            Int(field.prefix { $0.isNumber }) ?? 0
        }
    }
}
