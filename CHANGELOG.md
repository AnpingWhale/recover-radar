# 更新记录

## 0.2.0-preview.1 — 2026-10-31

首次公开预发布，MIT 许可证。

- Swift 6、SwiftUI、WidgetKit 原生 macOS 工程，无第三方依赖。
- 睡眠质量、HRV、静息心率、压力管理和运动负荷雷达；前 30 个完整日的个人中位数基线，基线随原值变化。
- 中号突出雷达和轴上数值；大号保留主雷达及当天值、基线对照表。
- macOS 26+ 原生 Liquid Glass 画廊与 WidgetKit 外观适配；旧系统材质回退。
- 本机时区自动配置、OAuth / PKCE、Keychain、MCP 读取、历史缓存及部分失败状态。
- 核心和接入层共 85 项合成测试；提供 Xcode 工程、CI、发布脚本和架构文档。

下载包为 Apple Silicon 主应用预览，不安装桌面 Widget，未签 Developer ID、未公证。真实 COROS 登录、正式 App Group 和桌面安装仍待验收。详见 [发布指南](docs/RELEASING.md)。
