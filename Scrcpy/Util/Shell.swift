//  Shell.swift
//  Scrcpy
//

import Darwin
import Foundation

struct ShellResult {
    let status: Int32
    /// stdout 与 stderr 合并后的内容，两者的相对顺序保持原样。
    let output: String
    let timedOut: Bool

    var ok: Bool { status == 0 && !timedOut }
}

/// 同步跑一个子进程并等它结束。
///
/// 存在的理由：`Process` 自己**没有**超时机制，而我们要调的 `adb` 在网络不通时
/// 能挂很久。每次调用都得自己配一套读取 + 超时的脚手架，不如收在一处。
enum Shell {

    /// 收到 SIGTERM 之后还给它多久自己退。正常进程收到就该退了，
    /// 这个宽限期是留给「正在收尾」的。
    private static let terminateGrace: TimeInterval = 2
    /// 等管道 EOF 的额外上限。进程退出不等于我们已经把输出读干净了。
    private static let drainGrace: TimeInterval = 2

    /// 同步执行并等待，带超时。超时则先 `terminate()`，宽限期内不退再 SIGKILL。
    ///
    /// - Parameter environment: **整体替换**语义，与 `Process.environment` 一致；
    ///   传 `nil` 才继承父进程环境。需要「继承 + 覆盖」的调用方必须自己从
    ///   `ProcessInfo.processInfo.environment` 起头再改，否则会丢掉 HOME、PATH 这些。
    static func run(_ executable: URL,
                    _ arguments: [String],
                    timeout: TimeInterval = 20,
                    environment: [String: String]? = nil,
                    cwd: URL? = nil) -> ShellResult {

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment ?? ProcessInfo.processInfo.environment
        if let cwd { process.currentDirectoryURL = cwd }

        let pipe = Pipe()
        // stdout 与 stderr 接同一个管道。分开接的话两路输出的先后关系会丢，
        // 而合并之后更接近用户在终端里看到的样子。
        process.standardOutput = pipe
        process.standardError = pipe
        // 别让子进程继承我们的 stdin：有些工具会去读它，一读就卡住。
        process.standardInput = FileHandle.nullDevice

        let lock = NSLock()
        var collected = Data()
        let exited = DispatchSemaphore(value: 0)
        let drained = DispatchSemaphore(value: 0)

        // 必须在 run() 之前挂上：子进程可能在这一行之前就把输出写完并退出，
        // 那部分输出会直接丢。
        //
        // 用 readabilityHandler 边读边攒，而不是 run() 之后 readDataToEndOfFile()：
        // 后者要等管道关闭才返回，输出超过管道缓冲（几十 KB）时子进程会阻塞在 write 上，
        // 双方互等，死锁。
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                // EOF。这里**必须**把 handler 置 nil，否则 availableData 会一直返回
                // 空 Data，这个 handler 就以 100% CPU 空转下去。
                handle.readabilityHandler = nil
                drained.signal()
                return
            }
            lock.lock()
            collected.append(chunk)
            lock.unlock()
        }
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            return ShellResult(status: -1,
                               output: "无法执行 \(executable.path)：\(error.localizedDescription)",
                               timedOut: false)
        }

        var reaped = exited.wait(timeout: .now() + max(0, timeout)) == .success
        let timedOut = !reaped

        if !reaped {
            if process.isRunning { process.terminate() }
            reaped = exited.wait(timeout: .now() + terminateGrace) == .success
        }
        if !reaped {
            // SIGTERM 可以被忽略，只 terminate 会漏进程。强杀是最后的兜底。
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            reaped = exited.wait(timeout: .now() + terminateGrace) == .success
        }
        // 回收僵尸。真走到这一步说明进程已经退出了，waitUntilExit 会立刻返回；
        // 万一没退出（不可能走到，除非 SIGKILL 都失败），也不能在这里无限等。
        if reaped { process.waitUntilExit() }

        // 进程退出 ≠ 我们已经把管道读干净：退出和读取是两条独立的路径。
        // 等 handler 自己在 EOF 时发信号，才能保证尾巴没丢。
        if drained.wait(timeout: .now() + drainGrace) == .timedOut {
            // 极少数情况下读端不会等到 EOF（比如子进程 fork 出的孙进程继承了写端）。
            // 摘掉 handler，用已经攒到的部分收场，不为了完整性把调用方拖住。
            pipe.fileHandleForReading.readabilityHandler = nil
        }

        lock.lock()
        let data = collected
        lock.unlock()

        return ShellResult(status: reaped ? process.terminationStatus : -1,
                           // 解码用 lossy 形式：子进程输出未必是合法 UTF-8，
                           // 不能因为一个坏字节就把整段输出变成空串。
                           output: String(decoding: data, as: UTF8.self),
                           timedOut: timedOut)
    }
}
