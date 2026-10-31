# COROS MCP 接入与验证记录

更新日期：2026-10-30。原生 OAuth、MCP 传输、严格日值解析与同步代码已实现。通过现有平台 COROS 连接完成了五项只读工具的响应及历史覆盖核对；**尚未完成本应用的真账号浏览器授权和签名后的小组件验收**。本文只记录响应结构和覆盖情况，不保存真实健康数值、账号信息或令牌。

## 证据分层

| 证据 | 本轮结论 | 不能由此推导 |
| --- | --- | --- |
| 官方公开文档、登录脚本 | 区域端点、公共客户端、PKCE、刷新轮换和 COROS 传输约定 | 本应用 loopback 回调和真账号登录已验收 |
| 无认证发现端点 | 返回授权、注册、令牌、撤销元数据及 scopes | 未登录请求的路由就是用户账号区域 |
| CN 动态注册兼容性检查 | 自定义 scheme 回调被 HTTP 400 `invalid_redirect_uri` 拒绝，没有创建客户端 | loopback 动态注册及登录已经成功 |
| 现有平台 COROS 连接上的只读查询 | 五项工具的英文按日文本；此次各有 31 个日期 | 原生 OAuth 已验收、所有账号或区域必有同样历史 |
| 注入式单元测试与合成报告 | 协议、解析、隔离和失败处理的可重复验证 | 真实 Keychain、签名、Widget 注册已验证 |
| 原生 macOS 应用端到端 | 待完整 Xcode、签名和用户在应用内授权后验收 | 不提前宣称可发布 |

MCP 不要求客户端使用大语言模型。Recover Radar 使用固定只读调用及确定性计算，不需要模型 API、Python、Node.js、本地 MCP 服务或第三方 Swift 库。[MCP Tools](https://modelcontextprotocol.io/specification/2025-11-25/server/tools)

## 服务与认证依据

| 项目 | 公开依据 / 实现选择 |
| --- | --- |
| 默认发现入口 | `https://mcp.coros.com/mcp`；首次按本机时区推定区域；已有连接保持授权区域 |
| 区域入口 | 中国大陆 `mcpcn.coros.com`；欧洲 `mcpeu.coros.com`；美国及其他地区 `mcpus.coros.com`，MCP 路径均为 `/mcp` |
| 公共客户端 | 动态注册使用 `token_endpoint_auth_method: none`，授权码和 PKCE `S256`，无内嵌 client secret |
| 发现 | `authorization_endpoint`、`registration_endpoint`、`token_endpoint`、`revocation_endpoint` 来自所选区域元数据 |
| scopes | `openid`、`mcp.tools`、`offline_access`；未发现健康数据专用只读 scope |
| 令牌期限 | 公开 FAQ 说明 access token 30 天、refresh token 180 天，刷新会轮换；代码以响应的 `expires_in` 为准 |

公开来源：[接入指南](https://github.com/coroslab/COROS-MCP/blob/9f58a4bc698720eccf66bf7e4e89cbb18e4c76cd/docs/zh/getting-started.md)、[FAQ](https://github.com/coroslab/COROS-MCP/blob/9f58a4bc698720eccf66bf7e4e89cbb18e4c76cd/docs/zh/faq.md)、[官方登录脚本](https://github.com/coroslab/COROS-MCP/blob/9f58a4bc698720eccf66bf7e4e89cbb18e4c76cd/skill/coros_mcp_login_gateway/scripts/coros_mcp_login.py#L300-L319)。

初始化阶段对默认主机的 [OAuth Metadata](https://mcp.coros.com/.well-known/oauth-authorization-server)、[OIDC Discovery](https://mcp.coros.com/.well-known/openid-configuration) 和 [Protected Resource Metadata](https://mcp.coros.com/.well-known/oauth-protected-resource) 请求得到 CN issuer。这只说明该次未认证请求的路由，不用于推断用户区域。

还有一个需要原生联调的差异：当时 Protected Resource Metadata 的 `resource` 是 `https://mcpcn.coros.com`，官方登录脚本采用完整 `/mcp` URL。本应用目前与官方脚本一致，绑定所选区域的完整 `/mcp` URL；两者不能假定可互换。实际服务接受情况必须在原生授权验收中记录。

### 原生认证已实现内容

1. 用户在应用内开始连接后，先通过 `prepareCallback()` 用 Network.framework 绑定 `127.0.0.1` 随机可用端口，再发现并注册公共客户端。动态注册、授权请求及授权码交换始终使用完全相同的 `http://127.0.0.1:<port>/callback`。所有 COROS 请求使用所选区域的 HTTPS 端点，拒绝跨主机、意外端点参数和网络重定向。
2. `NSWorkspace` 打开用户默认浏览器。回调服务只监听 IPv4 loopback；要求 GET、正确 Host 和 `/callback`、唯一且匹配的 state，并校验重复 code/error 等安全参数。授权码解析另外验证回调 URI、state 及返回的 issuer；PKCE 使用安全随机数和 `S256`。监听请求上限 8 KiB、单连接短超时、整体最多 5 分钟，成功、失败、超时或取消均关闭监听。
3. 主应用 Keychain 保存访问 / 刷新令牌、client ID、到期、区域、资源绑定及随机连接 UUID；不保存账号密码，不将凭证写入 UserDefaults、文件或 Widget。
4. `OAuthSession` actor 合并并发刷新，成功轮换后一起写回凭证。刷新失败明确要求重新连接；注册、授权码交换和刷新请求不自动重放。
5. 断开先使旧操作失效并删除本地凭证，再尽力撤销远端令牌；返回“本地已移除 / 远端撤销未确认”的区别。应用另外负责等待同步停止并清除历史与共享快照。

### 回调兼容性检查与变更

2026-10-30 对 CN 注册端点做了一次自定义回调兼容性检查：`recoverradar://oauth/callback` 返回 HTTP 400，错误类别为 `invalid_redirect_uri`，没有创建 client。本应用因此改用官方登录示例中的 loopback 回调方式，不再以自定义 scheme 进行 OAuth。保留的 `recoverradar://dashboard` 仅用于打开主窗口。

loopback 是短时本地 HTTP 回调，对 COROS 的连接和浏览器授权地址仍为 HTTPS。主应用增加 `com.apple.security.network.server` 以允许沙盒内监听；Widget 不启用网络权限。真实随机端口注册、用户登录、回跳、取消和令牌轮换仍须在原生应用验收。应用取消会关闭监听，但不会代用户关闭默认浏览器里的页面；用户可以返回应用查看最终状态。

未使用官方示例中的密码流程或 Python 凭证文件。

设计参考 [OAuth for Native Apps](https://www.rfc-editor.org/rfc/rfc8252) 和 [MCP 授权规范](https://modelcontextprotocol.io/specification/2025-11-25/basic/authorization)。应用只执行读取工具，不等于服务端令牌拥有只读权限；文档和 UI 不作这种声明。

## MCP 传输已实现内容

客户端协商当前支持的 `2025-06-18` 版本，先 `initialize`，检查 tools 能力，再分页读取 `tools/list`。调用前验证参数 schema，仅允许以下五个工具。其他工具即使被服务发现也不能执行。

按 COROS 当前官方约定，使用无状态流程，不依赖 `Mcp-Session-Id`，不发送 `notifications/initialized`。这是 COROS 兼容实现，不是通用 MCP 客户端行为。协议版本不匹配时停止，而不是自动猜测新版本。[官方脚本](https://github.com/coroslab/COROS-MCP/blob/9f58a4bc698720eccf66bf7e4e89cbb18e4c76cd/skill/coros_mcp_login_gateway/scripts/coros_mcp_login.py#L657-L715)、[COROS 接入说明](https://github.com/coroslab/COROS-MCP/blob/9f58a4bc698720eccf66bf7e4e89cbb18e4c76cd/skill/coros_mcp_login_gateway/SKILL.md#notes)、[MCP 生命周期](https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle)

请求声明 `Accept: application/json, text/event-stream`，支持 JSON 与 SSE。SSE 收到对应请求 ID 的结果后结束读取；响应大小、时间、分页数量均设上限。客户端拒绝意外响应 ID、HTTP 错误、JSON-RPC 错误、工具 `isError` 和未知内容类型，不执行服务通知或文本里的指令。[MCP 传输规范](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports)

GET/HEAD 和允许列表内的 MCP 只读调用采用有界重试；429 尊重 `Retry-After`，超过本轮等待预算则停止，留待后续同步。401 只允许受控刷新一次。离线、限流、格式失败都保留已有数据及其旧时间，不能用 HTTP 200 当作数据完整性的证据。

## 五项工具：本轮观察与适配

通过现有平台 COROS 连接完成各工具 `days: 1` 查询及以下历史查询。历史观察窗口为 **2026-09-30 至 2026-10-30（含两端）**；本次五项结果各包含 31 个日期。这里只记录结构和日期数量，不记录个人数值。

| 雷达维度 / 工具 | 本轮历史请求 | 观察到并解析的日值 | 仍然存在的边界 |
| --- | --- | --- | --- |
| 睡眠质量 `querySleepOverview` | `startDate: 20260930`、`endDate: 20261030` | `Sleep Overview` 中每日期的 `Sleep Score` | 评分接受域是本地规则；其他语言和格式变更不自动兼容 |
| HRV `querySleepHrv` | 相同显式起止日期 | `HRV Assessment` 中的 `HRV Avg`，单位 `ms` | 忽略 `Sleep HRV Time Series`；不以原始序列重算均值 |
| 静息心率 `queryRestingHeartRate` | `days: 31` | 日期行后的数值，单位 `bpm` | 未提供显式起止日期接口；与本机日期窗口不符时停止该轴更新 |
| 压力管理 `queryStressLevel` | `days: 31` | 每日期的 `Average Stress` | 平均压力不是恢复评分；缺失佩戴不能当作 0 |
| 运动负荷 `queryTrainingLoadAssessment` | `days: 31` | 每日期的 `Load Ratio` | 具体滚动计算窗口待进一步官方确认；不宣称安全区间 |

公开工具入口及参数依据：[健康工具说明](https://github.com/coroslab/COROS-MCP/blob/9f58a4bc698720eccf66bf7e4e89cbb18e4c76cd/docs/zh/tools.md#health)、[训练负荷说明](https://github.com/coroslab/COROS-MCP/blob/9f58a4bc698720eccf66bf7e4e89cbb18e4c76cd/docs/zh/tools.md#querytrainingloadassessment)。本次能返回 31 个日期，不是所有账号、所有区域或未来版本的覆盖保证；有效日数仍逐轴计算。

### 当前解析契约

适配版本为 `coros-daily-text-2026-10-30`。本次结果是英文按日文本，`structuredContent` 可为 `null`，文本外层可能再包装成 JSON 字符串。适配器仅在确认为 JSON 字符串时解开这一层，不把内部模型字段当成服务 JSON schema。

解析器要求匹配已观察的标题、日期、字段和单位。HRV 只解析 Assessment 区段。明确的 `No data` 是缺失；重复日期、非法日期、越界日期、字段重复、数值或单位不合法都会使整轴本次结果失败。未知语言和报告形态返回“不支持此数据格式”，不寻找任意数字补齐字段，也不调用 LLM 猜测内容。

成功解析同时返回日值和**报告明确确认的日期集合**。同步只替换确认过的自然日区间；明确 `No data` 写缺失标记，完全没出现的日期保留旧历史。如果今天没有被明确确认，本轴显示同步未完成，不把仅更新历史说成今日更新。这样既能反映服务撤回，又不会把短窗口或截断的报告误当成全窗口清空。

`observedAt` / `updatedAt` 目前记录成功读取时间，因为该文本格式没有稳定来源修订时间。它们不表示生理测量时刻，也不能证明设备刚上传。某轴查询失败时，其缓存时间不变；快照 `generatedAt` 仅表示文件生成时间。

测试报告全部为人工合成，参照确认后的形态构造；没有把本次真实响应保存成 fixture。日志、截图、仓库及共享快照不包含令牌、姓名、账号标识、完整健康记录或原始序列。

## 30 天基线与同步策略

基线使用本机日 D 的前 30 个完整日，当前日 D 单独展示，首次查询共需 31 个自然日。按产品要求，时区自动跟随 Mac，不再要求用户选择。工具没有提供可依赖的账号时区；本机时区不必等同于账号设置，若报告日期与请求窗口不符则明确降级，不推测或平移日期。

`AutomaticConnectionConfiguration` 以时区标识（而非 UTC 偏移）推定首次区域：中国大陆时区为 CN，Europe/* 及明确列出的欧洲大西洋时区为 EU，其余为 US。它是默认策略，并不验证账号归属；不同区域注册的账号可能仍需要进一步服务路由支持。已有授权固定其 issuer；时区改变只重建日期窗口与隔离缓存，绝不把已有令牌发给另一区域。

当前每次同步重取该 31 日窗口，简单覆盖近期补传及修订。睡眠使用一个显式日期范围；HRV 每批最多 7 个自然日，控制不使用的日内序列响应大小，**这是本应用的分批策略，不是官方显式日期范围的已证实上限**。其他三项使用 `days: 31`，返回日期仍需校验。

本地保存 90 个自然日的规范化历史，作用域是随机连接 UUID、区域及本机时区。每日只留最新修订；未提供的日不补零，已明确撤回的日保留缺失修订防止旧值复活。某轴读取失败，其他轴仍可同步；原值、基线样本天数及安全失败原因分别显示。

如果某账号或未来服务只能给出较短历史，保留现有日值并逐日积累。界面显示 N/30 天，少于 7 天不画该轴比较；不借用别的账号、别的指标或演示值。负荷只比较相同日值字段，不拿周累计替代。

具体统计方法、暂定值及显示方向见 [指标规范](METRICS.md)，存储与取消隔离见 [架构](ARCHITECTURE.md)。

## 验收门槛

| 项目 | 当前状态 | 下一步验收 |
| --- | --- | --- |
| 原生认证 | loopback / OAuth / Keychain / PKCE / 刷新 / 撤销代码已实现；CN 拒绝自定义 scheme 的证据已记录 | 签名应用随机端口动态注册、默认浏览器登录和回跳、取消、真实轮换和断开 |
| 数据形态 | 五个工具本轮英文文本结构已观察，严格解析器已实现 | 原生客户端接入后的相同形态；其他区域和语言变化降级 |
| 历史覆盖 | 本次五工具各返回 31 个日期 | 不同佩戴覆盖、缺失与截断时显示准确 N/30 |
| 同步存储 | 私有历史、逐轴失败、v2 原子快照已实现 | 真机离线、唤醒、跨日、换号、清理后的 Widget 行为 |
| 桌面发布 | 原生工程、主窗口、菜单栏、登录启动选项及 CLT 开发预览脚本已建立 | 完整 Xcode 构建、正式签名、App Group、Widget 注册、登录项、无障碍和 notarization |

取消授权、state 不符、区域错误、令牌过期、文本格式变化、工具缺失、部分失败和晚到响应必须保持可解释状态。生产连接入口属于待验收的开发功能。`scripts/build-preview.sh` 生成独立的主应用开发预览，不安装 Widget、不启用登录启动，并使用独立私有快照及 Keychain service。预览可运行不等于正式签名、沙盒权限、Widget 或完整授权流程已经通过验收。

## 公开来源版本与维护

初始公开仓库核对版本为 [`9f58a4bc698720eccf66bf7e4e89cbb18e4c76cd`](https://github.com/coroslab/COROS-MCP/tree/9f58a4bc698720eccf66bf7e4e89cbb18e4c76cd)。该仓库提供接入说明与 Agent 登录脚本，不提供这五项工具完整的稳定输出 schema；本项目没有复制其 Python 登录脚本或引入 npm 运行依赖。

发布前复核 [COROS 更新日志](https://github.com/coroslab/COROS-MCP/blob/main/changelog/CHANGELOG.zh.md)、区域发现元数据及实际 `tools/list`。服务格式变化时先确认新契约、更新合成样本和适配版本，再开放解析，不能通过放宽校验让未知数据混入历史。
