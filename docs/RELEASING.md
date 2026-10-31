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

## 正式桌面发行的必要条件

1. 使用完整 Xcode，按 [开发指南](DEVELOPMENT.md) 设置所有者的 Team、Bundle ID 与已获授权的 App Group。
2. 构建 Release archive，使用 Developer ID Application 证书及匹配的 provisioning 签名 app 和嵌入扩展，保留 Hardened Runtime 与 Sandbox。
3. 验证实际授权、回调、Keychain、共享容器读写、离线与过期状态，并在干净的 Mac 上安装中号和大号 Widget。
4. 使用 Apple `notarytool` 提交最终分发包并等待 Accepted；staple 票据，再验证签名、公证和 Gatekeeper。公证凭证只保存在发布者的 Keychain 或受限 CI secrets。
5. 在支持的 macOS 版本检查外观与辅助功能后，才能去掉预发布标记。若宣称支持 Intel，须另行构建并验收对应架构；本次本地包只验证 arm64。

当前机器没有完整 Xcode 或有效代码签名身份，无法完成上述正式发行步骤。GitHub CI 检查完整 app / extension 的无签名编译，不代表签名、COROS 真实授权或 Widget 安装已通过。
