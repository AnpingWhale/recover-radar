# 开发与本机运行

## 工具链

macOS 14+，Swift 6，完整应用开发支持 Xcode 16+。原生 Liquid Glass 画廊分支需要 Xcode 26+，或配套的 Swift 6.2+ 与 macOS 26 SDK；Xcode 16 的旧编译器会排除该分支，使用系统材质。运行目标最低仍为 macOS 14，在 macOS 14 / 15 上也使用系统材质。请使用配套工具链和 SDK，单独升级 Swift 编译器不等于获得新系统 API。

`xcode-select -p` 指向 `/Library/Developer/CommandLineTools` 时，可以构建独立主应用预览和运行测试，但不能使用完整 Xcode 的签名、扩展打包及安装流程。

```sh
swift --version
swift build
./Scripts/test.sh
```

测试使用工具链内置的 Swift Testing，无外部依赖。脚本通常执行 `swift test --disable-xctest`；对于只有 Command Line Tools 的环境，如果检测到工具链自带的 Testing 宏插件，则显式传入该插件搜索路径。本机 Swift 6.4 的默认查找会遗漏此目录，不能简单通过切换构建系统解决。脚本不下载依赖或更改系统工具链。

测试使用注入式传输、内存凭证和合成报告，不访问真实 COROS 账号或真实 Keychain；loopback 测试只访问临时本机端口。文件测试使用临时目录。

## 不安装 Xcode 的主应用预览

```sh
./Scripts/build-preview.sh
open 'build/Recovery Radar Preview.app'
```

脚本构建 Swift Package 的静态库并链接原生主应用，输出 ad-hoc 签名的 `.app`。它不是发行包，也不含 Widget 扩展；窗口明确显示“本地开发预览”。预览 Bundle ID 是 `org.example.RecoverRadar.Preview`，使用独立的 Keychain service 与私有 Application Support 缓存，不模拟 App Group，也不启用登录启动。

预览凭证保存在本机 login Keychain；正式签名版使用 Data Protection Keychain。该选择只由明确的预览构建标记决定，没有遇错自动降级。未带签名 entitlement 的 ad-hoc 程序访问 Data Protection Keychain 会返回 `-34018`，已用临时合成项确认，临时项已删除。

首次运行可点击“预览演示”。真实连接直接点击“连接 COROS”；地区与日期窗口按本机时区自动配置，由用户本人在默认浏览器授权。客户端先绑定本机回环地址的随机端口，再用该回调地址注册并发起 PKCE 授权；授权完成后回到应用查看同步结果。默认五分钟超时，也可在应用内取消。

登录实现已经过合成测试，但本应用的真实账号端到端授权仍待验收。已有平台 COROS 连接不能转移其令牌给本应用。不要将预览凭证或真实健康记录作为测试 fixture。

主窗口点击“查看桌面小组件效果”，打开中号 / 大号共用布局的独立预览窗口，可切换浅色和深色。画廊使用合成数据，参考尺寸不等于系统最终尺寸；尚未注册桌面 Widget。符合上述工具链及运行系统条件时，画廊的玻璃外壳使用原生 `glassEffect` 和 `GlassEffectContainer`；减少透明度或增强对比度时使用不透明底色。旧系统和旧工具链回退到 `.regularMaterial`。

运行 `./Scripts/render-widget-previews.sh` 可将同一内容布局输出到 `build/widget-preview-light.png` 和 `build/widget-preview-dark.png`。脚本明确传入 `usesNativeGlass: false`：`ImageRenderer` 无法捕获系统玻璃合成，这些 PNG 使用不透明底色，**只用于布局参照，不是 Liquid Glass 截图**。玻璃效果需在实际运行的画廊窗口观察，桌面效果仍需签名后的 Widget 验收。

## 正式工程：签名与 App Group

1. 将 `Configuration/Local.xcconfig.example` 复制为 `Configuration/Local.xcconfig`。
2. 设置自己的 `DEVELOPMENT_TEAM`、唯一 `APP_BUNDLE_IDENTIFIER`、`WIDGET_BUNDLE_IDENTIFIER` 和 `APP_GROUP_IDENTIFIER`。扩展 Bundle ID 保持以 app Bundle ID 为前缀。
3. 在 Apple Developer / Xcode 中为同一 Team 的两个 target 启用相同 App Group。`Local.xcconfig` 已被忽略，勿提交私人配置。
4. 打开 `RecoverRadar.xcodeproj`，选择共享 scheme **RecoverRadar**，运行目标 **My Mac**，确认两个 target 的 Signing & Capabilities 无错误。
5. 主应用需要 App Sandbox、网络客户端、网络服务器（仅 OAuth 回环监听）与 App Group；Widget 只有沙盒和 App Group，没有网络或凭证权限。
6. 运行主应用，连接并同步，或在未连接时将明确标识的演示写入小组件。成功保存后才请求 Widget 刷新。
7. 在 macOS 桌面右键 → 编辑小组件，找到 Recovery Radar，添加中号或大号。

```sh
cp Configuration/Local.xcconfig.example Configuration/Local.xcconfig
open RecoverRadar.xcodeproj
```

App Group 配置同时进入 entitlement 和 Info.plist，源码无需硬编码自己的标识。共享容器不可访问时界面显示配置错误，正式工程不会悄悄改用私有快照目录。默认采用 `group.` 前缀；仅修改字符串不会自动授予权限。[Apple 官方说明](https://developer.apple.com/documentation/xcode/accessing-app-group-containers)

## 构建与验收

```sh
# 完整 Xcode：检查 app 与嵌入的 extension 编译，不验证签名和安装
xcodebuild -project RecoverRadar.xcodeproj \
  -scheme RecoverRadar \
  -configuration Debug \
  -destination 'generic/platform=macOS' \
  -derivedDataPath build/CI \
  CODE_SIGNING_ALLOWED=NO build
```

GitHub Actions 执行 Swift 测试及无签名的 app / extension 构建；工作流已写入，尚无远端 CI 运行记录。

真实账号验收应覆盖首次注册、浏览器取消、登录成功、令牌轮换、断开后本地清理；仅使用本人账号，不记录令牌或完整健康响应。核对五轴原值、N/30 天、部分失败保留原时间、无当日数据、跨账号日、休眠与离线恢复。App 运行期间约每小时同步，回到窗口时按 15 分钟间隔检查，手动同步立即执行；应用退出后不联网。

桌面人工验收覆盖中 / 大尺寸、深浅色、全彩、透明及着色外观；在 `accented` / `vibrant` 单色模式下确认今日实线、基线虚线、数值和演示标记仍能区分。切换“减少透明度”和“增强对比度”，确认系统背景、网格、标签和状态仍清晰；同时覆盖 VoiceOver、无缓存、损坏缓存、缺失轴、历史不足、午夜与六小时过期状态。应用画廊的辅助功能回退和 WidgetKit 的系统背景替换分别验收，主应用预览与独立类型检查不能代替桌面验收。

Widget 的 `containerBackground` 保持可移除。透明或着色外观由 WidgetKit 替换背景，扩展只根据 `widgetRenderingMode` 调整内容，不另叠应用画廊的 `glassEffect`。[Apple：小组件 Liquid Glass](https://developer.apple.com/documentation/widgetkit/optimizing-your-widget-for-accented-rendering-mode-and-liquid-glass) · [可移除背景](https://developer.apple.com/documentation/widgetkit/displaying-the-right-widget-background)

## 常见问题

**找不到小组件**：预览包不安装 Widget。正式包应包含 `PlugIns/RecoverRadarWidget.appex`，正确签名并至少运行过主应用；随后重新打开小组件选择器。

**无法连接或回调超时**：核对网络；首次服务区域由本机时区推定，若账号在其他区域注册，当前自动推定可能不匹配；正式包还需网络服务器 entitlement。浏览器应访问当前流程的 `127.0.0.1` 回调，不能复用已取消或已超时页面。具体区域兼容性仍需真实登录验证。

**缓存不可访问**：核对两个 target 的 Team、App Group、entitlement 和 provisioning。预览与正式包的缓存彼此隔离。

**格式不支持或单项失败**：当前只解析已确认的英文日值报告，格式变化不会猜测修复。界面保留旧值和其原读取时间，重新同步或更新适配器；不要在公开 Issue 贴真实报告。

**小组件没有立即更新**：保存成功后只是请求 WidgetKit 重载，实际刷新由系统决定。扩展读取缓存不会同步 COROS；启用菜单栏可方便保持主应用运行。

**没有看到透明玻璃**：真实 Widget 的外观由 macOS 和用户的桌面外观设置控制，全彩模式可以显示普通背景；辅助功能设置也可能降低透明度。应用画廊还需 macOS 26+ 和新 SDK 构建。静态导出的 PNG 固定使用不透明底色，不能用来判断原生玻璃是否生效。

## 本次验证记录

2026-10-30 环境：macOS / arm64、Apple Swift 6.4、Command Line Tools。

- 85 项合成测试通过：Core 34 项，自动配置 / 认证 / MCP / 解析 / 同步 51 项；包括固定刻度下基线移动、相同原值位置稳定、范围裁剪及旧 v2 快照拒绝；也覆盖同 UTC 偏移的地区区分、旅行保留已授权区域，以及真实本机 socket 的回调校验和关闭测试。
- 主应用预览编译并完成 ad-hoc 签名；Widget 源码在扩展 API 限制下通过 Swift 6 类型检查。
- 工程、Info.plist 与 entitlement 格式校验通过；共享仪表盘用合成数据离屏渲染检查。
- 已修复并验证菜单栏重复回写造成的界面冻结。实际窗口确认连接区采用本机自动配置、连接按钮可用，不再保留时区输入或地区选择；小组件画廊可打开并切换浅 / 深色。未发起真实授权。
- 完整 `xcodebuild`、Apple 签名、App Group 实机授权、桌面安装及真实账号登录尚未验收。本机缺少完整 Xcode，主应用交互及离屏渲染不能替代真实 Widget 视觉验收。

### 菜单栏状态回写回归检查

本机曾出现 `MenuBarExtra` 在更新配置时重复回写相同可见性，触发 `@Published` 再次发布，造成 Scene 持续刷新、输入和按钮无响应。进程采样确认了这条循环。菜单栏和设置 Toggle 现在统一调用 `setShowMenuBar`，在赋值前过滤相同值；不能将去重放进 `didSet`，此时发布已经发生。

修改菜单栏或状态绑定时，在实际运行的应用检查：首屏连接按钮可用、演示能显示、菜单栏开启和关闭后仍可滚动及点击。仅编译或确认进程存在无法发现此问题。预览启动也不查询登录启动服务；正式版只在启动恢复阶段读取一次状态。

### Xcode 26.6 Release 编译

Swift 6.3.3 在 Release 构建中将 MainActor 隔离的 Bool setter 方法直接传给 `Binding(set:)` 时，曾在主应用的 IR 生成阶段崩溃。开关绑定采用显式闭包调用 setter，保留主线程语义和菜单栏相同值过滤；不要为了规避编译器问题移除状态去重。
