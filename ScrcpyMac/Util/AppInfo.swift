//  AppInfo.swift
//  ScrcpyMac
//

import Foundation

/// 当前 App 的身份与位置。更新器要靠它回答三个问题：
/// 现在跑的是哪个版本、是不是同一个 bundle、要替换哪个路径。
enum AppInfo {

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    static var bundleID: String {
        Bundle.main.bundleIdentifier ?? "com.vincerise.scrcpymac"
    }

    /// 解析过符号链接的 bundle 路径。
    ///
    /// 替换必须打在真实路径上：用户把 App 通过符号链接启动时，
    /// `bundleURL` 可能是链接本身，对它做 rename 只会换掉链接。
    static var bundleURL: URL {
        Bundle.main.bundleURL.standardizedFileURL.resolvingSymlinksInPath()
    }
}

/// App 在 Application Support 下的目录。
enum AppPaths {

    static var supportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("ScrcpyMac", isDirectory: true)
    }

    /// App 自更新专用的暂存与状态目录。
    static var updateDir: URL {
        supportDir.appendingPathComponent("app-update", isDirectory: true)
    }
}
