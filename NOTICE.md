# 第三方声明

本仓库（Scrcpy for macOS）是 [scrcpy](https://github.com/Genymobile/scrcpy) 的
**非官方 macOS 封装**。本仓库自身的代码以 MIT 授权（见 `LICENSE`）。

## scrcpy

- 作者：Romain Vimont（rom1v）及贡献者
- 主页：https://github.com/Genymobile/scrcpy
- 授权：**GNU General Public License v3.0**

### 关于再分发

本仓库**不包含也不分发** scrcpy 的任何二进制文件。这一点是刻意的：

- 仓库里没有 `scrcpy` / `adb` / `scrcpy-server`，只有本项目自己写的 Swift 与 shell 代码。
- 运行时所需的引擎由以下两种方式之一取得，且都直接来自上游官方渠道：
  1. `scripts/fetch-engine.sh` 在**构建时**从 Genymobile/scrcpy 的 GitHub Releases 下载；
  2. App 首次启动或用户点「检查更新」时，`UpdateChecker` 从同一个 Releases 地址下载。
- 下载内容以同一次 release 提供的 `SHA256SUMS.txt` 校验完整性。

因此本仓库分发的只是「一个会去调用 scrcpy 的独立程序」，不构成对 scrcpy 的再分发。
如果你要把**构建产物**（`.app`）分发给别人，那个产物里含有 scrcpy 的二进制，
届时你需要自行遵守 GPLv3 的相应义务。

### 关于完整性校验的边界

`SHA256SUMS.txt` 与 tarball 来自同一个 release，**只能证明下载没有损坏，
不能证明上游仓库没有被投毒**。真正的信任锚是同目录下的 `SHA256SUMS.txt.asc`
（rom1v 的 GPG 签名），但校验它需要本机安装 gpg，本项目没有引入这个依赖。

App 的更新界面会如实写成「已验证 SHA256（完整性）」，不会宣称做了签名验证。

## Android Debug Bridge (adb)

- 版权：Google LLC
- 授权：Apache License 2.0
- adb 由 scrcpy 的官方 release 一并提供，本项目同样只是在运行时调用它。
