# ScrcpyMac

把 [scrcpy](https://github.com/Genymobile/scrcpy) 命令行工具包成一个原生的 macOS 应用：
出现在启动台、可以固定到程序坞、双击就能投屏，**自带两条更新通道**——App 本体跟随本仓库
的 Releases，scrcpy 引擎跟随官方 Releases，各自检查、各自安装。

> 非官方封装。scrcpy 由 [rom1v](https://github.com/rom1v) 开发，以 GPLv3 授权。
> 本项目不重分发它的二进制，详见 [NOTICE.md](NOTICE.md)。

![ScrcpyMac 主界面](docs/images/main-window.png)

## 功能

- **设备**：自动列出 `adb devices`，多台设备可同时投屏、各自独立控制；USB 直连；一键把某台 USB 设备切到 Wi-Fi 连接
- **画面**：分辨率上限、码率、帧率上限
- **行为**：音频转发、投屏时息屏、保持唤醒、窗口置顶、停止投屏后自动息屏
- **录制**：投屏同时录成 mp4，文件名带时间戳
- **高级**：任意 scrcpy 参数直接透传
- **应用更新**：对比本仓库的最新 release，下载通用包并校验 SHA256 与签名后，在 App 自己的进程里原子替换并重启
- **引擎更新**：对比 GitHub 上 `Genymobile/scrcpy` 的最新 release，校验 SHA256 后原地替换本地引擎

不做按键映射（需要这个请用 QtScrcpy），也不修改 scrcpy 本身——全部能力都来自它的命令行参数。

[escrcpy](https://github.com/viarotel-org/escrcpy)（Electron）和
[QtScrcpy](https://github.com/barry-ran/QtScrcpy)（Qt）是功能更全的图形前端。
ScrcpyMac 的定位是：原生 SwiftUI、体积小、不捆绑 scrcpy，引擎跟随官方版本更新。

## 安装

### 直接下载

从 [Releases](https://github.com/vincerise/scrcpy-macos/releases) 下载最新的通用包，解压后把 `ScrcpyMac.app` 拖进「应用程序」。

包是 ad-hoc 签名、未经过公证，首次打开如果被系统拦下：macOS 14 及更早可以右键点 App
选「打开」；macOS 15 起这个入口没有了，要去「系统设置 → 隐私与安全性」点「仍要打开」。

### 从源码构建

需要 Xcode（或 Command Line Tools）与 [XcodeGen](https://github.com/yonaskolb/XcodeGen)：

```bash
brew install xcodegen
git clone https://github.com/vincerise/scrcpy-macos.git
cd scrcpy-macos
xcodegen generate
scripts/build.sh
scripts/install.sh
```

`scripts/install.sh` 会把 App 装到 `/Applications` 并刷新启动台与程序坞的缓存。

### 引擎

仓库里**没有** scrcpy 的二进制。App **首次启动时会自动**从官方 Releases 下载一份
（约 12MB）到 `~/Library/Application Support/ScrcpyMac/engine/`，装完就能用。

想让它离线自带一份（比如要给别的机器构建，或者不想让它联网），构建前先跑：

```bash
scripts/fetch-engine.sh                          # 从官方 Releases 下最新版
scripts/fetch-engine.sh /path/to/scrcpy-folder   # 或从本地已解压的目录拷
```

> 正式发布的安装包不会带引擎。把 scrcpy 的二进制打进安装包属于重分发，
> 会触发 GPLv3 的传染性，本项目的代码就不能再用 MIT 了。
> 自己构建时带引擎是本地使用，不涉及分发。

## 使用

1. 手机上打开「开发者选项 → USB 调试」，用数据线连上电脑
2. 手机弹出「允许 USB 调试吗」时点允许
3. 打开 ScrcpyMac，设备列表出现手机型号后，点那一行的「投屏」

**多台设备**：插几台就有几行，每行各自有「投屏 / 停止」。底部按钮是全局的：
一台设备时是「开始投屏」，多台时是「全部投屏」；已经在投的时候还会多一个
「投屏另外 n 台」，方便中途插进来的设备直接接上。同时投屏时每台设备是独立的
scrcpy 进程，各控各的设备；窗口默认按阶梯错开（「行为」里可以关掉），
日志区可以筛出只看某一台。模拟器不会出现在列表里——它本来就跑在这台电脑上，
再投一遍只是把眼前的画面重复一次。

> 同一台手机不要同时用 USB 和无线各开一路：这是两个不同的 serial，
> 界面会当成两台设备，但屏幕只有一块。

**参数按设备分开**：分辨率上限、视频码率、帧率上限、转发音频、投屏时关不关手机屏幕、
停止后熄不熄屏、窗口置顶、要不要录制、额外参数——这些都是每台设备一套。
设备列表那一行就是参数选择器：点一下选中，下面几张卡片改的就是它，
作用域条上写着这台是「跟随默认」还是「单独设置」。

![按设备参数](docs/images/settings.png)

行尾 `⋯` 菜单里还有三个动作，它们改的是别的设备，所以收在菜单里：

| 动作 | 作用 |
| --- | --- |
| 恢复默认参数 | 这台改回跟随默认，别的设备不动 |
| 把这台设为默认 | 把这台的当前值变成默认值，**只影响以后插进来的设备**；已经在用的其他设备保持原样 |
| 应用到所有 n 台设备 | 把这台的值覆盖到其他所有设备上（两个以上设备时才出现） |

一台设备都没插时，卡片改的是**默认参数**，也就是以后新插进来的设备用的那份；
想单独设置某一台，插上它、点一下那一行再改。

投屏中改参数不会打断当前这一路——已经在跑的那条命令行是启动那一刻定下的，
**改动下次投屏生效**（作用域条会写明这一点）。

「多台时错开窗口」「录制保存目录」「adb 路径」这三项是全局的，在最后一张卡片里。

**找回投屏窗口**：投屏窗口是独立的 scrcpy 进程开的，被别的窗口压住之后有几个入口能把它拎回来——
双击设备那一行、行尾 `⋯` 菜单里的「显示投屏窗口」，或者右键程序坞图标
（菜单里会列出每一台正在投屏的设备）。点程序坞图标则是把控制面板和所有投屏窗口一起带到前面。

控制面板始终位于投屏窗口之上，这是 macOS 的激活机制决定的。点「显示投屏窗口」时，
如果面板正好挡着，App 会把面板自己挪到不重叠的一侧。

**停止后息屏**：在「行为」里打开「停止投屏后让手机息屏」，投屏结束（点停止，或直接关掉投屏窗口）
之后会往设备发一次 `KEYCODE_SLEEP` 把屏幕按灭。它发生在 scrcpy 退出**之后**——
开了「投屏时关闭手机屏幕」的话，scrcpy 自己退出时会把屏幕恢复成亮的。

**切到无线**：在设备行的 `⋯` 菜单里点「切换到无线」。成功后可以拔线，
下次直接点「投屏」即可（手机和电脑要在同一个 Wi-Fi 下）。
无线设备也在同一个列表里，「断开连接」同样在 `⋯` 菜单里。

**更新**：卡片上有两行，互不影响——「ScrcpyMac 应用」跟着本仓库的 release，
「scrcpy 引擎」跟着 `Genymobile/scrcpy` 的 release。两行各自检查、各自下载；
菜单里的「检查更新…」会同时触发两者。每次启动也会在后台静默看一次，只有发现新版才出声。

![两条更新通道](docs/images/updates.png)

App 更新下载并校验完成后，按钮变成「重启并更新到 x.y.z」。点下去 App 会**原地替换自己**
然后退出，后台 helper 等它退出后重新打开新版本；30 秒内没确认启动就自动回滚。
投屏中可以检查、下载，但「重启并更新」要求先停止投屏；引擎正在更新时也不能同时更新 App。

引擎更新下载并校验通过后原地替换，下次投屏生效；更新期间不能投屏。
scrcpy 跳大版本时命令行参数也可能变，所以**装不装由你点**。

## 它是怎么工作的

### 引擎放在 App 外面

```
ScrcpyMac.app/Contents/Resources/engine-seed/        ← 只读种子，随 bundle 一起被签名，永不修改
~/Library/Application Support/ScrcpyMac/engine/      ← 更新替换的那一份
~/Library/Application Support/ScrcpyMac/Mirror.app/  ← 启动子进程用的迷你 bundle
```

运行时按这个顺序找引擎：**先看 Application Support，没有再回落到内置种子**。
所以从源码构建、没跑过 `fetch-engine.sh` 的版本一启动就会下载一份到 Application Support；
带种子的版本开箱即用，直到点过一次「检查更新」，之后生效的就是 Application Support 里那份新的。

引擎放在 bundle 外面，而且引擎更新**从不写 bundle**：

- ad-hoc 签名会 seal `Resources/`，替换里面的二进制会让 `cdhash` 变化，
  连锁导致所有 TCC 授权失效（本地网络权限反复弹窗，用户一旦点过「不允许」
  就再也不会弹，无线 adb 会静默失败）
- 从压缩包直接双击运行时，macOS 会把 App 挂到随机只读路径（App Translocation），
  此时写 bundle 必然失败
- App 若由 root 拥有，写入需要提权

引擎外置把这几个问题一次消掉，而且引擎更新**不需要重新签名**。

App 本体更新是唯一的例外：它按用户点击整体替换 bundle，签名随之改变，
macOS 可能因此重新询问「本地网络」权限。这是 ad-hoc 签名没有稳定身份导致的，
允许一次即可；详见常见问题。

### 签名

ad-hoc 签名（`codesign -s -`），没有 Developer ID。本地构建不带 quarantine，
所以不会弹「未识别开发者」。换成别人下载的构建产物就会弹——这是 ad-hoc
签名无法避免的，它永远无法通过公证。

签名时**不加 `--deep`**：引擎里的 `adb` 带 Google 的 Developer ID 签名，
`--deep` 会把它一并重签成 ad-hoc，毁掉那个签名。

### 更新

两条通道互不依赖。

**App 本体**

```
GET /repos/vincerise/scrcpy-macos/releases/latest   （带 ETag，304 就跳过）
  → ScrcpyMac-v<ver>-macos-universal.zip
  → 校验 SHA256：优先用 API 的 asset digest，没有就用 SHA256SUMS.txt；
    两者都有时必须一致，都没有就拒绝安装
  → ditto 解压，要求恰好一个 .app
  → codesign --verify --strict（不加 --deep）+ bundle id / 版本号 /
    架构 / 最低系统版本
  → 用户点「重启并更新」
  → 当前进程内 renamex_np(RENAME_SWAP) 原子交换 bundle
  → helper 等旧进程退出后重新打开；30 秒内没有确认就回滚
```

`codesign` 只能证明这个包完整、没有被改坏；ad-hoc 签名没有身份，任何人都能重新签一份。
真正的信任锚是 HTTPS 下载的 release 资产和它的 SHA256。

替换发生在 App 自己的进程里，而不是让 helper 去改 bundle：macOS 13 起 App Management
对「另一个进程修改 App bundle」的限制更严，而 App 修改自己通常不需要额外授权。
`renamex_np` 在非 APFS 卷上会失败，这时直接报错，不做两次 rename 的非原子回退——
中途崩溃会留下一个打不开的启动路径。

新版本启动后会写一个 ack 文件，helper 收到匹配的版本号才删掉旧包；没有 ack 的旧版本
（这套机制之前发布的那些）只要进程稳定存活 5 秒也按成功处理。新版本起不来时会重试拉起，
最后仍失败就把旧包换回去并重新打开。

**引擎**

```
GET /repos/Genymobile/scrcpy/releases/latest   （带 ETag，304 就跳过）
  → 按本机架构选 scrcpy-macos-{aarch64,x86_64}-v<ver>.tar.gz
  → 下载，取同 release 的 SHA256SUMS.txt 校验
  → tar 解压 → 清扩展属性 → 跑一次 scrcpy --version 冒烟
  → 同文件系统内两次 rename 原子切换
```

引擎更新**必须整体替换**：`scrcpy` 客户端与 `scrcpy-server` 的版本必须严格一致，
只换其中一个会被拒绝启动。

### 子进程不占程序坞

scrcpy 使用的 SDL3 Cocoa 后端会把进程设成 `NSApplicationActivationPolicyRegular`，
于是程序坞里会多出一个图标，菜单栏也会被它接管。要得到 accessory 策略
（没有程序坞图标、不占菜单栏，但窗口能激活、键盘鼠标照常），两件事缺一不可：

1. **子进程要待在一个带 `LSUIElement` 的 bundle 里。** 进程的默认激活策略由 AppKit
   按「它是不是在 bundle 里」决定：裸二进制是 prohibited，bundle 加 `LSUIElement`
   才是 accessory。所以不直接 exec 引擎目录里的 scrcpy，而是在
   `~/Library/Application Support/ScrcpyMac/Mirror.app` 里放一个迷你 bundle
   （`Contents/Info.plist` 带 `LSUIElement`，`Contents/MacOS/scrcpy` 优先用硬链接
   指向当前引擎，跨卷才退化成拷贝），exec 的是它。
2. **要设置 `SDL_MAC_BACKGROUND_APP=1`。** SDL 在拿到这个 hint 之前会主动调用
   `setActivationPolicy:Regular`，把 bundle 里的 `LSUIElement` 盖掉。

只做第 2 步（裸二进制 + hint）也不行：进程策略会变成 prohibited，图标没了，
但窗口起不来，投屏是黑屏。迷你 bundle 每次启动都会重建一次（内容一致时不落盘），
所以引擎更新之后 `scrcpy` 与 `scrcpy-server` 的版本仍然是对齐的。

## 常见问题

**手机一直显示「未授权」**
手机屏幕上应该有一个「允许 USB 调试吗」的弹窗，点允许。如果没弹，
拔插一次数据线，或在开发者选项里点「撤销 USB 调试授权」再重连。

**切到无线之后连不上**
确认手机和电脑在同一个 Wi-Fi，且没有开 AP 隔离。另外 macOS 15 起
`adb connect` 会触发「本地网络」隐私授权，第一次弹窗时要点允许；
一旦点过不允许，之后不会再弹，要去「系统设置 → 隐私与安全性 → 本地网络」
里手动打开。

**关掉 App 之后手机上的 scrcpy 服务还在跑**
正常退出（⌘Q 或关窗口）会给 scrcpy 发 SIGTERM，它会自己清理。
只有在 App 被强制杀死（`kill -9`）时才可能残留，App 下次启动会自动清理。

**同一台手机用 USB 和无线连，为什么是两行**
`adb` 眼里它们是两台设备：USB 那个 serial 是硬件序列号，无线那个是 `IP:端口`。
参数也是各存各的——想让两边一致，就在其中一行上用 `⋯` 里的「应用到所有 n 台设备」。
整份按设备存的参数都存在 `scrcpy.deviceSettings` 这一个键里，
要全部清掉就 `defaults delete com.vincerise.scrcpymac scrcpy.deviceSettings`。

**视频码率该选多少**
选「自动」：走 USB 时取这台手机编码器自报的上限（从设备上的 `media_codecs*.xml` 读，
常见机型在 40–100 Mbps），走 Wi-Fi 时给 8 Mbps。读不出上限的老机型在 USB 上给
20 Mbps，1080p60 下已经是肉眼无损的量级。下拉框里的档位也是按这台设备的上限列的；
真要越过它，用「额外参数」里的 `--video-bit-rate`。

**能不能只更新其中一个**
可以。两行各有「检查更新」，点哪行只查哪个；菜单里的「检查更新…」才会两个一起查。

**更新 App 时按钮是灰的**
行下方的提示会写明原因：正在投屏、引擎正在下载或安装、另一个同 bundle id 的实例在跑、
位置只读或不可写、或者 App 是从压缩包里直接运行的（App Translocation）。把 App
拖进「应用程序」再更新。如果是 App Management 拦截，去「系统设置 → 隐私与安全性 →
App 管理」允许 ScrcpyMac。

**更新 App 之后「本地网络」又弹了一次**
ad-hoc 签名没有稳定身份，bundle 一换 `cdhash` 就变，macOS 会把新版本当成另一个 App。
允许一次即可。每次更新都可能重弹，直到有 Developer ID 并公证。

**更新失败会不会把 App 弄坏**
不会无声地弄坏。替换前会完整校验，替换后读不到新版本号会立刻换回；helper 等不到
新版本启动会把旧包换回去并重新打开。最坏情况是两个版本都没起来，可以从 Releases
重新下载；设置和引擎都在 `~/Library/Application Support/ScrcpyMac/`，不受影响。

**检查更新提示「额度用完」**
GitHub 对匿名 API 限每小时 60 次，引擎和 App 共用这个额度。等一会儿再点。

## 开发

```
ScrcpyMac/
├── App/        入口、菜单、AppDelegate
├── Design/     主题与通用组件
├── Engine/     引擎定位、引导、原子替换
├── Device/     adb 调用与输出解析
├── Session/    scrcpy 子进程的生命周期
├── Update/     App 与引擎的更新检查、下载、校验、安装
├── Model/      偏好设置持久化
└── UI/         主界面与视图模型
```

`project.yml` 是工程配置的唯一事实来源，`.xcodeproj` 不进仓库——改完 Swift 文件
跑一次 `xcodegen generate` 即可。

发布包：`scripts/release.sh` 从 `project.yml` 读版本号，构建不带引擎种子的通用包，
检查签名与架构，生成 `SHA256SUMS.txt`，最后打印 `gh release create` 命令（不自动发布）。

## 授权

本项目代码以 [MIT](LICENSE) 授权。
scrcpy 归 rom1v 所有，GPLv3；adb 归 Google，Apache-2.0。详见 [NOTICE.md](NOTICE.md)。
