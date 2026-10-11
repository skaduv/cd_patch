# Claude Desktop Patch

用于 Windows x64 Claude Desktop 的本地 PowerShell 补丁脚本。生成可注册的开发版应用目录，无需重新打包或发布 MSIX。

脚本在独立副本中调整模型、工具与遥测相关代码，更新 ASAR 完整性哈希及 EXE 内嵌哈希，并备份原始文件。默认仅准备副本；只有指定 `-Activate` 才会替换当前用户的应用注册。

## 功能

下文的 **1p** 指 Claude 官方服务模式，**3p** 指第三方推理提供方模式。

- **模型名称**：Gateway/Mantle 接受非空且不含控制字符的模型 ID，保留原始 ID。
- **模型发现**：默认启用 Gateway 自动发现，移除发现结果中的厂商名称过滤，按原始 ID 去重，并与手填模型清单合并；保留分页、部分失败结果及认证检查。
- **Computer Use / Browser Use**：适配新版主进程与启动阶段的本地规则表，默认开启内置浏览器；保留显式关闭、组织策略、系统权限、授权有效期和服务可用性检查。
- **工具搜索**：默认启用 `toolSearchEnabled`，1p 使用 host 模式并向 Code 子进程传递开关；3p 保留新版 host、legacy 和提供方兼容模式的选择逻辑。
- **WebFetch**：默认启用 `skipWebFetchPreflight`，跳过向 Anthropic 查询域名的预检，保留网络白名单和工具权限。
- **遥测**：默认启用 `disableEssentialTelemetry` 和 `disableNonessentialTelemetry`，在 1p 模式中强制关闭对应遥测，并设置 Code 子进程禁用遥测、错误报告的环境变量。
- **备份与恢复**：修改前自动备份，恢复前后校验 SHA256。
- **离线设置入口**：主窗口顶部保留 40px 本地菜单栏，左上角菜单不依赖官网登录页加载；通过“文件 → Configure Third-Party Inference…”打开内置第三方 API 配置页，地区不可用或断网时也能进入。配置页可离线填写，验证凭据和调用模型仍需连接对应提供方。

自动发现、工具搜索、WebFetch 预检跳过和内置浏览器设置允许显式 `false` 关闭；1p 遥测使用强制覆盖。

## 环境要求

- Python 3.10 或更高版本。
- Node.js 24 或更高版本，用于检查新版 JavaScript 语法。
- 激活修改版时，需要开启 Windows 开发者模式，并使用同一 Windows 用户以管理员身份运行 PowerShell。此版本包含 Windows 服务，普通权限无法完成注册；脚本会在移除当前注册前检查权限。

## 快速开始

### 1. 开启开发者模式（仅激活时需要）

仅检查兼容性或准备副本时，可以跳过此步。

按 **Win + I** 打开 Windows 设置，搜索“开发者模式”，开启并确认提示。

- 新版 Windows 11：**系统 → 高级 → 开发者选项**。
- 较旧 Windows 11：**隐私和安全性 → 开发者选项**。
- Windows 10：**更新和安全 → 开发者选项**。

无需开启设备门户或设备发现。参见 [Microsoft 开发者模式文档](https://learn.microsoft.com/en-us/windows/advanced-settings/developer-mode)。

### 2. 检查兼容性

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "\路径\Patch-ClaudeDesktop.ps1" -CheckOnly
```

检查应用结构、补丁匹配、JavaScript 语法和生成结果的完整性，不激活或启动应用。默认优先检查已有副本；没有副本时读取当前官方安装。指定 `-MsixPath` 时会先提取到副本目录。

### 3. 准备副本并按需激活

只准备修改版副本，保留当前 Claude 的注册状态：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "\路径\Patch-ClaudeDesktop.ps1"
```

需要切换到修改版时，以同一 Windows 用户身份打开管理员 PowerShell，再运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "\路径\Patch-ClaudeDesktop.ps1" -Activate
```

脚本准备修改副本并完成校验后，询问是否替换当前用户的 Claude 应用注册。输入 `y` 后继续。

不加 `-Activate` 只准备副本。默认目录为 `\路径\ClaudeDesktop-Patched`；如检测到先前的旧命名目录，脚本会继续使用该目录及其原始备份。

激活后，重启 Claude 并新建会话，使会话设置生效。界面语言使用 Claude 官方提供的语言设置，脚本不下载、替换语言资源或修改语言菜单。

### 4. 更新已有副本

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "\路径\Patch-ClaudeDesktop.ps1" -PatchOnly -Activate
```

自定义过安装目录时，添加相同的 `-InstallDir`。`-PatchOnly` 只更新已有副本的补丁，不升级 Claude 本体。旧副本版本不同时，请从当前官方安装创建新的 `-InstallDir`，不要混用不同版本的文件或备份。

## 备份与恢复

资源备份位于安装目录的 `patch-backup`。重复应用补丁保留首次原始基线，不会用修改后的文件替换原始备份。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "\路径\Patch-ClaudeDesktop.ps1" -Restore
```

`-RestoreOriginal` 是 `-Restore` 的同义参数。恢复无需 Node.js，仍需要 Python。

恢复会还原脚本修改的 EXE、ASAR 和前端文件；旧版备份中记录的新增文件仍会按清单删除。恢复不会回退账号数据或恢复官方签名安装的应用注册方式。回到官方安装方式需要重新安装官方包。

激活前另行保存原应用布局与用户数据快照，位于 `registration-backup`。快照可能包含登录信息，应仅在本机保管。

## 参数

| 参数 | 说明 |
| --- | --- |
| `-CheckOnly` | 检查兼容性与补丁结果 |
| `-Activate` | 注册修改版并启动 |
| `-PatchOnly` | 使用已有副本，不重新复制安装布局 |
| `-Restore` | 恢复原始程序资源 |
| `-InstallDir <路径>` | 指定修改副本目录 |
| `-MsixPath <路径>` | 从原版 MSIX 提取应用 |
| `-PythonPath <路径>` | 指定 Python 可执行文件 |
| `-NodePath <路径>` | 指定 Node.js 可执行文件 |
| `-NoLaunch` | 激活后不启动应用 |
| `-Yes` | 跳过应用注册替换确认 |

## 已知限制

- 补丁严格检查版本和每个替换点的匹配数量；Claude 更新后需要重新适配。
- 修改 EXE 会使原 Anthropic 数字签名失效；脚本会重新计算并保留 ASAR 完整性校验。
- 客户端仍使用 Anthropic Messages 协议；任意模型名称通过校验，不代表网关或模型支持全部工具协议。
- 工具搜索、Computer Use 和 Browser Use 的实际可用性取决于后端能力、组织策略及系统授权。
- 遥测修改未经过完整联网抓包验收，独立 OTLP 导出不在覆盖范围内，不能保证所有遥测流量为零。


## 免责声明

本项目仅供学习与技术研究，使用者应遵守适用法律及相关服务条款，并自行承担使用、修改或分发本项目的风险与责任。
在适用法律允许的最大范围内，本项目不作任何明示或默示保证，作者及贡献者不对使用本项目产生的损失或责任承担任何责任。
