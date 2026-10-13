# Claude Desktop Patch

用于 Windows x64 Claude Desktop 的本地 PowerShell 补丁脚本。直接修改当前 Windows 用户已注册的 Claude 安装目录。

脚本原地调整模型、工具与遥测相关代码，更新 ASAR 完整性哈希及 EXE 内嵌哈希，并备份原始文件。不复制整套应用，不卸载或重新注册应用。ASAR 采用流式单遍校验与重建，峰值内存约为单个文件大小，而非数倍于整个包。

## 功能

下文的 **1p** 指 Claude 官方服务模式，**3p** 指第三方推理提供方模式。

- **模型名称**：Gateway/Mantle 接受非空且不含控制字符的模型 ID，保留原始 ID。
- **http Base URL**：第三方推理的 Base URL（Gateway、Bedrock、Vertex、Foundry）允许任意主机的 `http://`，不再报 “must use https (or http on loopback)”；语音输入复用 Gateway 地址时同样放行。MCP、OAuth 等其他地址仍保持原有 https 校验。注意 http 会明文传输 API 密钥，仅建议在内网或本机使用。
- **模型发现**：默认启用 Gateway 自动发现，移除发现结果中的厂商名称过滤，按原始 ID 去重，并与手填模型清单合并；保留分页、部分失败结果及认证检查。
- **Computer Use / Browser Use**：适配新版主进程与启动阶段的本地规则表，默认开启内置浏览器；保留显式关闭、组织策略、系统权限、授权有效期和服务可用性检查。
- **工具搜索**：默认启用 `toolSearchEnabled`，1p 使用 host 模式并向 Code 子进程传递开关；3p 保留新版 host、legacy 和提供方兼容模式的选择逻辑。
- **WebFetch**：默认启用 `skipWebFetchPreflight`，跳过向 Anthropic 查询域名的预检，保留网络白名单和工具权限。
- **遥测**：默认启用 `disableEssentialTelemetry` 和 `disableNonessentialTelemetry`，在 1p 模式中强制关闭对应遥测，并设置 Code 子进程禁用遥测、错误报告的环境变量。
- **简体中文**：使用 Anthropic 官方中文（语言代码 `zh-Hans`）。安装包已自带官方原生界面资源 `resources/zh-Hans.json`，但内置前端（离线/第三方模式使用）缺少 `zh-Hans` 资源且语言列表未包含它。脚本从 `https://claude.ai/i18n/` 下载官方 `zh-Hans.json`、`dynamic/zh-Hans.json` 和 `zh-Hans.overrides.json`，按 key 与本机 en-US 资源合并后写入 `ion-dist/i18n`，在前端受支持语言列表中加入 `zh-Hans`，语言菜单显示“中文（简体）”。官方资源中缺少的条目保留英文。
- **备份与恢复**：修改前自动备份，恢复前后校验 SHA256。
- **离线设置入口**：仅在登录页（地区不可用提示所在页面）顶部留出 40px 本地菜单栏，左上角菜单不依赖官网页面加载；正常使用时不占位置。通过“文件 → Configure Third-Party Inference…”打开内置第三方 API 配置页，地区不可用或断网时也能进入。配置页可离线填写，验证凭据和调用模型仍需连接对应提供方。
- **重复运行秒退**：仅当以下全部成立时直接退出：`patch-report.json` 未被恢复过、补丁引擎指纹（`engineSHA256`）与当前一致、EXE / 当前 ASAR / 前端 asset / 语言资源的完整 SHA256 与报告记录一致、且本次合并出的语言资源与已安装的相同（上游更新后会重新应用）；若上次跳过了语法校验而本次需要校验，则不走跳过、重新执行。
- **进度与诊断输出**：ASAR 校验/重建按 64MB 打进度；启动时打印实际使用的 Python/Node 路径与版本；结束 Claude 进程时打印数量。Python 会做真实 `--version` 探测，Microsoft Store 占位符会被识别并跳过。

自动发现、工具搜索、WebFetch 预检跳过和内置浏览器设置允许显式 `false` 关闭；1p 遥测使用强制覆盖。

## 环境要求

- Python 3.10 或更高版本。
- Node.js 24 或更高版本，用于检查补丁后 JavaScript 语法；找不到时自动跳过校验并警告（也可用 `-SkipSyntaxCheck` 显式跳过）。
- 已安装并为当前 Windows 用户注册 Claude Desktop。
- 修改和恢复需要管理员权限及安装目录写入权限。脚本会自动处理：非管理员时弹出 UAC 并以管理员身份重新运行自身（输出在新窗口中，结束后按回车关闭）；WindowsApps 目录默认归 TrustedInstaller 所有、管理员也只有只读权限，检测到不可写时脚本会先把原始 ACL 备份到 `%LOCALAPPDATA%\ClaudeDesktopPatch\acl-<包目录名>-<路径哈希>.txt`（另有 `.owners` 记录每个文件的原所有者，`.path` 记录完整安装路径和两份备份的 SHA256；复用和还原前都会校验，不一致则不改权限；还原时会拒绝指向安装目录之外或经过联接/符号链接的条目，且只恢复清单中记录的条目的所有者），再用 `takeown`/`icacls` 把所有权交给 Administrators，并授予 Administrators 和当前用户完全控制。改权限和关闭 Claude 前会先校验版本，不支持的版本不会关闭 Claude、也不会改任何权限；ACL 备份必须完整（icacls 无错误且条目数覆盖全部文件）才继续；若本次改了权限但补丁未完成，会自动还原权限。`-Restore` 会按备份还原 ACL 和每个文件的原所有者，资源恢复失败时也会尝试还原 ACL；还原失败时脚本以非零退出码结束并保留备份。不希望改权限时加 `-NoAclChange`。UAC 请用同一 Windows 用户确认（换账号提权会找不到当前用户注册的 Claude）。无需开启开发者模式。

## 快速开始

### 1. 检查兼容性

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "\路径\Patch-ClaudeDesktop.ps1" -CheckOnly
```

自动定位当前用户已注册的 Claude，检查应用结构、补丁匹配、JavaScript 语法和生成结果的完整性。不修改程序文件、不关闭或启动应用。

### 2. 修改当前安装

退出 Claude，在 PowerShell 中运行（非管理员时会自动弹出 UAC）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "\路径\Patch-ClaudeDesktop.ps1"
```

脚本会关闭目标安装目录下仍在运行的 Claude 进程，检查写入权限（必要时备份 ACL 并接管权限），备份原始资源并直接写入补丁。完成后手动启动 Claude，并新建会话使会话设置生效。应用注册和用户数据保持不变。

如果当前用户注册了多个 Claude 安装，可用 `-InstallDir` 指定其中一个安装根目录（包含 `AppxManifest.xml` 的目录）。该参数不能指向未注册的目录。

再次执行同一命令即可更新补丁，脚本保留首次原始资源备份。Claude 本体升级后，需确认新版本受脚本支持，并针对新的安装目录重新应用补丁；不要跨版本搬用备份。

完成后在 **Settings → Language** 选择“中文（简体）”。语言资源需要访问 claude.ai；所在网络或地区无法访问时，可用 `-LanguageDir` 指定离线目录（按 `zh-Hans.json`、`dynamic/zh-Hans.json`、`zh-Hans.overrides.json` 的结构存放从 `https://claude.ai/i18n/` 取得的文件，后两者可省略），或用 `-NoLanguage` 跳过中文。下载失败时不会修改任何程序文件。若上次补丁写过本次不会再写的文件（例如旧版的 `zh-CN` 资源，或装过中文后改用 `-NoLanguage`），脚本会拒绝运行并提示先执行 `-Restore`。

## 备份与恢复

资源备份位于安装目录的 `patch-backup`。重复应用补丁保留首次原始基线，不会用修改后的文件替换原始备份。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "\路径\Patch-ClaudeDesktop.ps1" -Restore
```

`-RestoreOriginal` 是 `-Restore` 的同义参数。恢复无需 Node.js，仍需要 Python。

恢复会还原脚本修改的 EXE、ASAR 和前端文件并删除新增的语言资源，并按备份还原安装目录的 ACL 与原所有者；旧版备份中记录的新增文件仍会按清单删除。恢复不会回退账号数据或更改应用注册。若备份丢失，可重新安装官方包恢复程序文件。

## 参数

| 参数 | 说明 |
| --- | --- |
| `-CheckOnly` | 检查兼容性与补丁结果 |
| `-Restore` | 恢复原始程序资源 |
| `-InstallDir <路径>` | 选择当前用户已注册的 Claude 安装根目录 |
| `-PythonPath <路径>` | 指定 Python 可执行文件 |
| `-NodePath <路径>` | 指定 Node.js 可执行文件 |
| `-SkipSyntaxCheck` | 跳过 JavaScript 语法校验（无 Node.js 时自动跳过并警告） |
| `-NoAclChange` | 不自动接管或还原安装目录权限 |
| `-LanguageDir <路径>` | 使用离线保存的官方 `zh-Hans` 前端资源，不联网下载 |
| `-NoLanguage` | 不安装简体中文 |

## 已知限制

- 补丁严格检查版本和每个替换点的匹配数量；Claude 更新后需要重新适配。
- 自动接管权限会修改 WindowsApps 中该包目录的所有者和 ACL，可能影响 Microsoft Store 更新或修复；用 `-Restore` 还原，或重新安装官方包。
- 修改 EXE 会使原 Anthropic 数字签名失效；脚本会重新计算并保留 ASAR 完整性校验。原地修改不会更新 MSIX 包签名，Windows 的包完整性检查可能阻止启动或触发修复；官方更新也可能覆盖补丁。
- 客户端仍使用 Anthropic Messages 协议；任意模型名称通过校验，不代表网关或模型支持全部工具协议。
- 工具搜索、Computer Use 和 Browser Use 的实际可用性取决于后端能力、组织策略及系统授权。
- 前端中文取自 claude.ai 当前线上版本，可能比本机前端新；本机用到而官方资源缺少的条目保留英文，写死在代码里的界面文字仍为英文。
- 遥测修改未经过完整联网抓包验收，独立 OTLP 导出不在覆盖范围内，不能保证所有遥测流量为零。


## 免责声明

本项目仅供学习与技术研究，使用者应遵守适用法律及相关服务条款，并自行承担使用、修改或分发本项目的风险与责任。
在适用法律允许的最大范围内，本项目不作任何明示或默示保证，作者及贡献者不对使用本项目产生的损失或责任承担任何责任。
