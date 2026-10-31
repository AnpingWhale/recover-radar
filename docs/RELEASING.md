# 发布指南

## 0.2.0-preview.1

这是第一个 MIT 开源预发布版本，完整源码包含主应用、Widget 扩展和测试。下载的二进制仅为 Apple Silicon 主应用预览，使用 Release 优化编译；它不包含桌面 Widget，不具备 Developer ID 签名或 Apple 公证。不是经过验收的正式桌面发行版。

预览与正式工程使用隔离的凭证和缓存。它提供演示数据、小组件布局画廊及待真实账号验收的 COROS 连接功能。macOS 26+ / 新 SDK 可使用原生 Liquid Glass；macOS 14 / 15 回退到系统材质。图例、指标含义及数据限制见 README 与 METRICS。

## 重建预览发布包

在 macOS 上安装 Swift 6 的 Command Line Tools（原生玻璃需 Swift 6.2+ / macOS 26 SDK），然后运行：

```sh
./Scripts/test.sh
./Scripts/package-preview.sh
```

脚本生成 `build/releases/RecoverRadar-0.2.0-preview.1-<architecture>.dmg`、ZIP 和 `SHA256SUMS.txt`。只打包新构建的应用、许可证和用户说明，不包含本地缓存、Keychain、历史健康数据或签名材料。DMG 内应用可拖入 Applications；下载后的首次启动可能受 Gatekeeper 阻止。不要关闭 Gatekeeper；可使用源码构建，正式发行则必须完成下面的签名流程。

上传前核验散列：

```sh
cd build/releases
shasum -a 256 -c SHA256SUMS.txt
```

发布者应先确认 GitHub 账号为 AnpingWhale，等待 CI 通过，再将版本标签推送到对应提交，并使用 GitHub Release 的 **Pre-release** 标记发布文件及校验和。版本号同时维护于 `Configuration/Shared.xcconfig`、`Scripts/build-preview.sh` 与打包脚本；预发布后缀用于标签和文件名，应用内部使用 `0.2.0` / build `2`。

## 完整 app + Widget 构建

GitHub Actions 使用完整 Xcode 执行 Release 编译，确认 `.app/Contents/PlugIns/RecoverRadarWidget.appex` 存在后，上传 `RecoverRadar-with-Widget-unsigned` 构建产物，保留 14 天。它确实包含 Widget 扩展，但未签名、未获 App Group 授权，不应当作普通用户安装包。首个 Release 也永久保留了该构建，文件名带 `with-Widget-UNSIGNED-universal`；从 CI 下载后附加 MIT 许可证与开发说明重新压缩，二进制未修改，来源提交为 `92ffb086e824d2a1f6d428422b6ee2abc00ca485`，SHA-256 收录于发布校验和。可在仓库 Actions 的成功运行页下载，用于开发者检查工程输出。

## 正式桌面发行的必要条件

1. 使用完整 Xcode，按 [开发指南](DEVELOPMENT.md) 设置所有者的 Team、Bundle ID 与已获授权的 App Group。
2. 构建 Release archive，使用 Developer ID Application 证书及匹配的 provisioning 签名 app 和嵌入扩展，保留 Hardened Runtime 与 Sandbox。
3. 验证实际授权、回调、Keychain、共享容器读写、离线与过期状态，并在干净的 Mac 上安装中号和大号 Widget。
4. 使用 Apple `notarytool` 提交最终分发包并等待 Accepted；staple 票据，再验证签名、公证和 Gatekeeper。公证凭证只保存在发布者的 Keychain 或受限 CI secrets。
5. 在支持的 macOS 版本检查外观与辅助功能后，才能去掉预发布标记。本次 CI 已构建 arm64 与 x86_64；若宣称支持 Intel，还需 Intel 实机验收。本地预览包只验证 arm64。

当前机器没有完整 Xcode 或有效代码签名身份，无法完成上述正式发行步骤。GitHub CI 检查完整 app / extension 的无签名编译，不代表签名、COROS 真实授权或 Widget 安装已通过。

## 本次发布验证

- [GitHub CI](https://github.com/AnpingWhale/recover-radar/actions/runs/41183691448)：Xcode 26.6，85 项测试、完整双架构 app / Widget Release 编译及独立预览构建通过。
- 本机：Release 优化预览启动与画廊、菜单栏开关往返和恢复响应检查通过；DMG 完整性、ad-hoc 签名完整性、ZIP 内容及 SHA-256 校验通过。
- 未完成：Developer ID 签名、公证、App Group 授权、真实桌面 Widget 安装和完整账号授权回归。

Apple 官方说明：[Developer ID](https://developer.apple.com/developer-id/) · [软件公证](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)。
