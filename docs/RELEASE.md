# 发布指南

**中文** · [English](RELEASE.en.md)

项目发布物分成三类，必须分别验收：

1. **源码预览版**：源码、文档、测试和许可证；
2. **桌面二进制版**：额外携带 Python、依赖、FFmpeg/FFprobe、模型和 Flutter 应用。
3. **Android 侧载测试版**：额外携带 ONNX 模型、Rust Runtime 和 ONNX Runtime Android 库。

推送普通 `v*` tag 后，GitHub Actions 会自动构建 macOS Intel、macOS Apple Silicon、Windows x64 和 Android `arm64-v8a` 包；带平台后缀的热修复 tag 只构建该平台，规则见第 4 节。产物上传到对应 GitHub Release，**不会自动写入 OSS**；核验产物并手动演练后，另行手动发布生产通道。桌面包会携带便携 Python、依赖、FFmpeg/FFprobe 和 `models/bball_model.pt`；Android 包在 CI 中导出 ONNX 模型、编译 Rust Runtime，并下载官方 ONNX Runtime Android（QNN 版）和高通 QNN Runtime 库；预编译 NPU 模型随源码提交。

## 1. 源码公开前检查

### 应包含

- `README.md` 和 `README.en.md`；
- 入门、FAQ、开发、发布、架构和协议文档；
- `LICENSE`、`NOTICE`、`CONTRIBUTING.md`、`SECURITY.md`、`CODE_OF_CONDUCT.md`；
- 依赖、模型和数据授权边界说明；
- 模型、数据和截图的本地使用说明。

### 不应包含

- 未核验授权的模型/原生运行时二进制；桌面发布所需的 `models/bball_model.pt` 是当前明确的例外，仍应单独核对其授权；
- 真实比赛视频、导出片段、真实标注和未脱敏截图；
- `.venv/`、`.tooling/`、`build/`、`dist/` 和个人路径；
- API key、私钥、真实联系方式或第三方源码 checkout；
- 只在某台开发机上有效的依赖路径。

执行自动检查：

```bash
python3 scripts/check_open_source.py
.venv/bin/python -m pytest -q
cd apps/desktop
flutter analyze
flutter test
cd ../mobile
flutter analyze
flutter test
cd ../..
git diff --check
```

`check_open_source.py` 发现的 error 必须在公开前处理；warning 需要逐项判断并记录。当前源码树的具体阻塞项见 [`OPEN_SOURCE_AUDIT.md`](OPEN_SOURCE_AUDIT.md)。

## 2. 授权核验

| 对象 | 必须确认 |
|---|---|
| 源码 | MIT 文件是否随发布物保留 |
| Python 依赖 | 锁定版本、许可证和 notices |
| Flutter/Dart 依赖 | `pubspec.lock` 对应版本和 notices |
| FFmpeg/FFprobe | 编译配置、LGPL/GPL 边界和 notices |
| 模型代码 | 代码许可证和再分发条件 |
| 模型权重 | 是否允许公开下载或随包分发 |
| 训练数据 | 原始和衍生数据的公开处理权 |
| 演示视频/截图 | 人物、球队、场馆和画面的公开权利 |
| Android/iOS 原生库 | Rust、ONNX Runtime 和平台 SDK 的分发条件 |

如果模型或训练数据的权利无法证明，只发布源码，并要求使用者自行准备模型。详见 [`MODEL_AND_DATA_LICENSES.md`](MODEL_AND_DATA_LICENSES.md) 和 [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)。

## 3. macOS 构建

### 3.1 Debug 构建

```bash
cd apps/desktop
flutter pub get
flutter analyze
flutter test
flutter build macos --debug
```

这只验证 Flutter UI 构建，不代表 Python Engine、模型和 FFmpeg 已嵌入。

### 3.2 准备便携运行时

需要一个包含项目依赖的便携 Python 目录：

```text
portable-python/
└── bin/python3
```

该 Python 应能导入 `cv2`、`numpy`、`ultralytics` 和 `torch`。不要直接复制带有开发机绝对路径或本机动态库引用的 `.venv`。

FFmpeg 和 FFprobe 应使用自包含或静态构建。依赖 Homebrew 的版本只适合本机临时验证，可显式设置 `BHE_ALLOW_EXTERNAL_FFMPEG=1`，但这不代表可分发。

GitHub 临时 macOS 构建机会关闭 Spotlight 索引，以减少制作 DMG 时的资源占用。`scripts/create_macos_dmg.sh` 使用 HFS+，仅对 `Resource busy` 最多尝试 5 次；其他错误立即失败。镜像创建后执行 `hdiutil verify`，验证通过才生成摘要并上传。该策略对应 [GitHub runner 的已报告问题](https://github.com/actions/runner-images/issues/7522)。

### 3.3 准备运行时目录

把已授权模型放在：

```text
models/bball_model.pt
```

从仓库根目录运行：

```bash
BHE_PYTHON_RUNTIME=/path/to/portable-python \
BHE_FFMPEG=/path/to/static/ffmpeg \
BHE_FFPROBE=/path/to/static/ffprobe \
scripts/prepare_macos_runtime.sh dist/macos-runtime
```

准备脚本会复制 Engine、算法脚本、SQLite schema、模型和视频工具，并运行运行时检查。失败时不要继续构建 `.app`。

### 3.4 构建 Release `.app`

```bash
BHE_PYTHON_RUNTIME=/path/to/portable-python \
BHE_FFMPEG=/path/to/static/ffmpeg \
BHE_FFPROBE=/path/to/static/ffprobe \
FLUTTER_BIN="$(command -v flutter)" \
scripts/build_macos_release.sh
```

脚本默认生成可拖动安装的 `.dmg` 镜像和对应的 SHA-256 校验文件。DMG 内包含 `BHE.app`、`Applications` 快捷方式、使用说明和“一键修复与验证”脚本。打开 dmg 后，把 `BHE.app` 拖到 `Applications`，再双击 `BHE-首次打开修复.command` 即可。发布版本可显式传入版本号：

```bash
BHE_BUILD_NAME=0.1.0-alpha.2 \
BHE_BUILD_NUMBER=2 \
BHE_PYTHON_RUNTIME=/path/to/portable-python \
BHE_FFMPEG=/path/to/static/ffmpeg \
BHE_FFPROBE=/path/to/static/ffprobe \
scripts/build_macos_release.sh
```

未配置 `BHE_CODESIGN_IDENTITY` 时，脚本只做 ad-hoc 签名（本机临时签名），让嵌入运行时后的 `.app` 保持完整签名封装；这不等于 Apple Developer ID 签名，也不包含公证。该包适合开发者本机或测试机验证，不应直接当作面向公众的正式安装包。首次打开时若被 Gatekeeper 拦截，可在 Finder 中右键应用选择“打开”，或在确认来源可信后移除下载隔离属性。

如果系统仍然拦截已确认来源的应用，可以在终端执行：

```bash
xattr -dr com.apple.quarantine /Applications/BHE.app
open /Applications/BHE.app
```

需要签名时：

```bash
BHE_CODESIGN_IDENTITY="Developer ID Application: Example" \
BHE_PYTHON_RUNTIME=/path/to/portable-python \
BHE_FFMPEG=/path/to/static/ffmpeg \
BHE_FFPROBE=/path/to/static/ffprobe \
FLUTTER_BIN="$(command -v flutter)" \
scripts/build_macos_release.sh
```

`BHE_CODESIGN_IDENTITY` 只触发脚本的签名步骤，不等于已完成 Apple 公证或 Gatekeeper 验证。

### 3.5 干净机器验收

将 `.app` 放到没有源码仓库、Homebrew FFmpeg、开发 `.venv` 和个人模型路径的环境中，至少验证：

1. 应用能找到内置 Engine；
2. 可以创建项目并导入授权测试视频；
3. 可以读取元数据、自动或手动设置 ROI；
4. 标准分析可以完成；
5. 候选审核、时间调整和导出正常；
6. 重开项目后状态仍然存在；
7. 原视频移动后可以重新定位；
8. 没有向外部网络上传视频或模型数据；
9. 签名、公证和 Gatekeeper 安装流程通过。

## 4. Windows 实验性发布

准备运行时：

```powershell
powershell -ExecutionPolicy Bypass -File scripts\prepare_windows_runtime.ps1 `
  -PythonRuntime C:\path\to\portable-python `
  -Ffmpeg C:\path\to\ffmpeg.exe `
  -Ffprobe C:\path\to\ffprobe.exe `
  -OutPath dist\windows-runtime
```

构建并生成 zip：

```powershell
powershell -ExecutionPolicy Bypass -File scripts\build_windows_release.ps1 `
  -Version 0.1.0-alpha.3 `
  -PythonRuntime C:\path\to\portable-python `
  -Ffmpeg C:\path\to\ffmpeg.exe `
  -Ffprobe C:\path\to\ffprobe.exe `
  -RuntimeOut dist\windows-runtime `
  -Zip
```

脚本会生成 `dist\BHE-windows-x64-v0.1.0-alpha.3.zip` 和对应的 `.sha256` 校验文件。推送完整版本 tag 后，GitHub Actions 会为各平台构建并上传到 Release；平台补丁 tag 只构建对应平台。本地没有 Intel Mac 也不影响 Intel 包构建。

Windows 当前属于兼容路径，仍需验证 Flutter 工具链、Python/Torch/OpenCV/Ultralytics、FFmpeg DLL 和安装流程；它不能替代正式安装器、签名和用户验收。

### Windows 应用内安装更新

Windows 下载完成后提供「安装并重启」和「打开所在文件夹」。安装会先在程序目录外启动 PowerShell 助手，重新校验下载包的 SHA-256（文件内容摘要）、大小和目录结构，再解压到安装目录旁的暂存目录。助手就绪后，BHE 保存当前项目、明确等待引擎退出，收到助手接收确认后关闭窗口。助手等待 BHE 进程退出，依次重命名旧目录和新目录，再启动新版。分析、导出或其他操作进行中不能安装。

适用条件与保护范围：

- 仅支持 Windows x64 的便携 ZIP 发布包；使用系统自带 Windows PowerShell 5.1。企业策略禁止脚本时仍可手动更新。
- `build_windows_release.ps1` 会调用 `write_windows_release_inventory.ps1` 生成 `bhe-release.json`（程序文件清单），再放入 ZIP。**第一次引入此功能的版本仍须手动安装一次**；旧版不能直接获得自动替换能力。
- 助手检查已安装版和新版文件清单，拒绝额外文件、额外文件夹、符号链接或目录联接。因此项目、视频、自定义模型等个人文件应放在程序目录之外；检查不通过时不会关闭 BHE，也不会替换文件。
- 安装目录的父目录必须可写，需留出新版解压所需的磁盘空间。不会请求管理员权限；受保护目录请改用可写目录或手动更新。
- 旧版保留为同级的 `BHE.previous-<32 位十六进制编号>`（实际前缀随安装目录名变化），附带同级的 `.bhe-update.json` 归属记录。下一次更新的新进程通过基础启动检查后，会清理更早的、由本机制创建的备份，只保留本次更新的回退版本。仅名字匹配但没有归属记录、归属不符、含个人文件、存在链接或仍在运行的备份不会删除；清理失败不阻断更新，并记录到 `cleanup.log`。
- 替换或立即启动失败时尝试恢复并重新打开旧版；若文件仍被占用，则保留旧版目录和错误日志，并提示恢复路径。**进程存活检查不等于功能验收**，不会自动判断分析、导出是否正常。
- 两次目录重命名之间遇断电或进程被强制结束，仍可能需要人工恢复。关闭相关进程后，保留失败新版，按日志中的 `backup` 路径把旧目录改回原名称。失败流程不会清理旧备份，也不会更改项目数据库。

日志保存在 `%LOCALAPPDATA%\BHE\updates\install-*`：`status.json` 记录阶段与目录，`error.txt` 记录失败原因，`cleanup.log` 记录旧备份清理情况。暂存目录在安装目录旁，正常结束会清理；最近的回退备份、失败新版和中断遗留物保留。空的 `.update.lock` 作为稳定互斥文件保留；关闭句柄即释放锁，文件存在不表示更新仍在运行。

自动检查（只使用临时目录中的模拟程序，不操作真实 BHE）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\test_windows_update.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\test_windows_update_inventory.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\test_windows_patch_inventory.ps1
```

该检查已接入 Windows CI（持续集成，即每次推送或提交审查时自动运行）。上线前仍需在真实 Windows 发布包中验证：中文与空格路径；从版本 A 更新到 B；分析、导出期间禁用安装；程序目录混入项目时拒绝；其他进程占用文件时恢复；关闭窗口失败时保持应用可用；恢复旧版后项目可打开；更新后视频播放、分析和导出正常。

Windows 发布包采用不含 `libx264` 的 LGPL FFmpeg。导出依次尝试硬件编码 `h264_nvenc`（NVIDIA）、`h264_qsv`（Intel）、`h264_amf`（AMD）、`h264_mf`（Media Foundation），再尝试 `libx264`、`libopenh264` 和 `mpeg4`，仅在前一种编码失败时切换；第一个成功的编码器用于同一次导出的后续片段。最后一种使用高质量 MPEG-4 Part 2，仍封装为 MP4，但不保证所有仅支持 H.264 的播放器都能播放。逐片导出与合并失败后的重新编码采用同一规则。代理视频在 Windows 上先用 D3D11VA 显卡解码，失败时回退纯软件解码。打包前运行 `scripts/check_media_pipeline.py --root <runtime>`，实际生成代理、片段和合并视频；检查失败时停止打包。常规 Python CI 也会在 Windows 上用发布包同款 LGPL FFmpeg 执行该检查。

### 人工确认发布与分平台补丁（从 0.1.13 起）

`.github/workflows/release-packages.yml` 按标签选择构建平台。数字完整版本和已批准的平台补丁都可覆盖官网下载与 App 内检查更新：

| tag 示例 | 构建与通道更新范围 |
| --- | --- |
| `v0.1.13` | macOS 两架构、Windows x64、Android arm64-v8a；更新完整版本与全部包条目 |
| `v0.1.13-macos.1` | macOS 两架构必须同时存在；只替换这两个条目及官网别名 |
| `v0.1.13-windows.1` | Windows x64；只替换 Windows 条目及官网别名 |
| `v0.1.13-android.1` | Android arm64-v8a；只替换 Android 条目及独立 `app/android/bhe/latest.apk` 别名 |

补丁在 GitHub 仍标记为 pre-release（预发布），但这里的、已经批准进入生产通道的平台补丁会更新本平台的官网下载和 App 更新清单。不能仅凭 GitHub 的预发布标记判断是否上传 OSS。`v0.1.12-android.1` 那次仅供测试的历史发布不受此新规则追溯影响。

完整版本和 macOS、Windows、Android 补丁都遵循同一顺序：

1. 确认标签所指提交包含本门禁，再推送 `v*` 标签。Actions 构建并创建 GitHub Release；标签触发的 OSS job 会跳过，不修改官网或更新清单。
2. 检查 GitHub Release 的目标平台安装包、配套 SHA-256 校验文件、版本和内容；完整版本核验全部四个平台，macOS 补丁核验两个架构。标签本身与 GitHub Release 会公开，请按发布授权处理。
3. 在 **Upload existing release assets to OSS** 手动选择标签和对应平台，确认 `dry_run=true`（默认演练）。完整版本选 `all`，补丁选 `macos`、`windows` 或 `android`。此工作流下载该 Release 的资产并进行只读演练；核对 `publish-summary.json` 的 `status=dry-run-ok`、验签状态、候选版本和拟上传对象，以及 Actions 产物。
4. 演练通过并经人工检查和批准后，使用同一手动工作流、相同标签和平台，显式选择 `dry_run=false` 正式发布。检查 job 结果和 `publish-summary.json` 的 `status=success` / `stage=complete`，再核对官网与更新清单。

**这是人工操作门，不是自动审批或演练证明门禁。** 手动工作流的 `dry_run` 默认是 `true`；正式发布必须显式选择 `false`。执行前仍须主动核对；正式运行不会自动验证先前演练或锁定演练时的 Release 文件。两次运行分别下载 Release 资产，期间若资产被覆盖、通道变化或有并行发布，先重新核验摘要并重新演练。`BHE release packages` 的手动 `publish_oss` 仍可作为特殊入口，操作人员应避免绕过上述核验流程。

**首次真实使用仍须 Claude 与老大另行批准。开发验收只使用临时目录和测试密钥，不执行真实上传或读取真实私钥。**

#### 版本、说明和安装兼容性

`latest.json` 顶层 `version` 始终表示最新完整版本，补丁不改它。包条目可有 `version`、`notes`，例如 Android 的 `0.1.13+android.1`。App 构建版本使用 `+平台.N`，发布标签和包文件名继续使用 `-平台.N`。客户端先比较数字版本，再按整数比较平台补丁号：补丁 10 大于补丁 9，下一完整版本大于旧完整版本的任何补丁。

包含新逻辑的 0.1.13 起会使用本平台版本和说明；没有包级字段时回退顶层字段。检查、自动通知、弹窗和“跳过此版本”均使用平台版本。跳过补丁 1 不会屏蔽补丁 2；其他平台的补丁不会触发当前平台升级。

≤0.1.12 客户端无法识别同一完整版本下的补丁，但仍可跨完整版本升级；看到顶层 0.1.13 后，可能直接下载该平台最新的 0.1.13 补丁包，显示的说明仍是完整版本说明。

Windows 已安装的旧助手严格比较请求版本与 ZIP 内 `bhe-release.json.version`，不能更新已安装助手来解决兼容问题。**新的 Windows 补丁包将 `version` 保持为基础完整版本（如 0.1.13），另以 `release_version=0.1.13-windows.1` 记录补丁身份。** 新客户端也传基础版本给助手；包内容由签名清单中的 SHA-256 与大小绑定。助手原有版本、文件树、路径、摘要和进程检查不放宽。发布器会检查 ZIP 内两种版本，不兼容旧客户端的补丁包在任何上传前被拒绝，不能把旧格式补丁 ZIP 直接放入新通道。

macOS 继续手动替换安装包，不传严格版本请求；Android 继续仅把 APK 路径交系统安装器，不受 Windows 此问题影响。Android 签名证书和递增 `versionCode` 的既有要求保持。

完整版本与补丁的说明都取**标签对应的中英 README“最近更新”表精确版本行**。例如发布 `v0.1.13-android.1` 前，两份表必须都有该版本的非空说明。缺说明、使用重复版本行或借用其他版本均不允许，不能把 Unreleased 当成补丁说明。

#### 共同发布入口与串行保护

`BHE release packages` 的手动 `oss-upload` job 与 **Upload existing release assets to OSS** 的手动 job 都调用 `scripts/publish_release_update.py`；标签推送不进入 OSS job。正式发布共用 job 级锁 `bhe-production-update-channel-v1`，覆盖读取、验签、合并和全部通道写入；演练使用独立组 `bhe-dryrun-update-channel-v1`，主工作流同标签演练也使用独立并发组，避免挤掉排队中的正式发布。构建可并行，生产通道写入串行。

手动选择 `dry_run=true` 会读取、验签、合并、签名并预检同名对象，但不会写入 OSS 发布对象；Actions 会保存已生成的演练文件。主工作流还须同时启用 `publish` 和 `publish_oss`，否则计划阶段报错。`dry-run-ok` 不代表正式发布成功。检查备份中的 `publish-summary.json`：`previous_verified` 或 `candidate_verified` 为 false 时，对应文件只是待验证输入或未通过验签的候选；脚本未启动时可能没有备份，恢复前始终重新验签。

**已接受的限制：演练与正式发布可并行，没有程序门禁或跨组互斥；结果只反映读取当时的通道状态，不保证之后正式发布成功。** 即使演练验签并返回 `dry-run-ok`，并行发布也可能随后改变清单，使演练结果过期；在签名与清单切换之间读取还可能验签失败。真实发布进行中不要跑演练；如有并行的正式发布，或演练失败，先确认正式发布已经结束，再重新演练。

**GitHub concurrency 同组最多保留 1 个运行项和 1 个排队项，后来的排队项会取消更早的排队项；即使 `cancel-in-progress: false` 也不会保留所有排队项。** 它不是先入先出的可靠发布队列。需要逐个确认成功；多个任务入队后必须检查是否有 `cancelled`，不能认为它们最终都会发布。被取消的任务由监督者决定是否以手动入口重新发布，不自动重发。

发布器拿到锁后重新读取旧清单，先验签原始字节再严格解析（拒绝重复键）。只修改目标条目及 `published_at`，用整体 JSON dump 重新输出与签名；非目标条目、顶层版本/说明和扩展字段保持语义与键序。macOS 一次更新两个架构。后拿锁的不同平台补丁不会覆盖先完成的另一平台补丁。

生产发布顺序为：全部本地校验和候选签名验证 → 带版本资产 → 目标平台官网别名及摘要 → `latest.json.sig` → `latest.json` → 读回验签。客户端下载带版本文件，不使用可能继续变化的别名。已发布的同名文件只能内容一致，不能覆盖为不同内容；需要改变内容时使用新补丁号，不能反复重建同一标签冒充重试。

只有当前顶层完整版本的补丁可以发布，且基础版本至少为 0.1.13。倒序补丁、同版本不同内容、旧基础版本、用旧完整版本清单覆盖已发布补丁都被拒绝。全量生产发布必须有全部四个架构，正常发布也要求旧清单及签名存在并有效；本任务不提供清单损坏后自动重建或首次初始化入口。纯本地完整清单生成函数仍可单独使用。

在 **BHE release packages** 手动运行时：`publish=false` 只构建；`publish_oss=false` 可以只发布 GitHub。正常数字完整标签使用 `platform=all`；平台补丁标签必须选匹配的 `android`、`windows` 或 `macos`，不能用默认 all。开发/alpha 标签可构建 GitHub 预发布，但不被生产清单发布器接受；需要仅 GitHub 时显式关闭 `publish_oss`。

手动上传已有 Release 时也必须选择与标签一致的平台，并走同样的签名清单合并。发布工具取运行 workflow 的代码，说明取目标标签的 README；使用包含本机制的新 workflow 定义，不重跑历史无锁上传实现。`scripts/upload_release_assets_oss.sh` 的本地生产入口已关闭，防止绕过共同锁。

#### 失败、取消和观测

`latest.json` 与 `.sig` 是两个对象，不是原子事务。切换窗口中客户端可能暂时验签失败；如果第二个对象上传失败，通道可能持续不可用。客户端会拒绝不匹配的数据，不会静默信任。官网别名也不能与清单实现跨对象原子更新，别名中途失败时可能有目标架构已经更新而清单仍旧。

任何阶段失败都立即停止，不继续上传、不自动回滚生产对象。监督者按最后阶段和保留的旧可信清单、完整候选决定恢复方式。不能把失败报告成“通道完全未受影响”。外部人工直接改对象不受 GitHub 锁保护，禁止用它作为日常发布旁路。

脚本从开始写 `publish-summary.json`，持续记录 tag、平台、状态、最后阶段、对象和事件；可处理的中断记录 cancelled。强制终止可能只留下 running，不能将其当成功。workflow 计划摘要只是计划；最终结果摘要展示 OSS job 的 success/failed/cancelled/skipped。**排队就被取消的 job 没有运行过脚本，自然没有脚本摘要**，应检查 Actions job 状态和计划摘要，而不是等待不存在的日志。

发布 job 会尽量保留 `update-channel-<run_id>-<attempt>` artifact：摘要、旧清单/签名、候选及读回清单/签名；不包含私钥或 OSS 凭据。旧清单是否已验签成功要结合最后阶段判断，恢复前必须再次验签，不能把失败下载的备份直接当成可信数据。只有 job 成功且摘要 success 才表示发布完成。

#### 完全离线回归

新测试运行时生成临时 Ed25519 密钥、假包和本地目录，不读取真实密钥、不连接 OSS：

```bash
python -m pytest -q tests/test_platform_patch_manifest.py tests/test_publish_release_update.py tests/test_platform_patch_workflows.py
```

`test_full_013_publish_keeps_four_platforms_notes_signature_and_website_aliases` 覆盖从旧完整清单发布完整 0.1.13，验证四个条目、顶层版本/双语说明、官网别名和真实测试密钥签名。其余用例覆盖不同平台依次合并、macOS 双架构、防降级、旧 Windows 不兼容 ZIP、缺失/失效签名、错误密钥、同名资产冲突、各上传阶段和读回故障、取消摘要。

`--store-dir <临时目录>` 是发布器明确的离线传输模式，没有网络回退。真实通道模式需要显式 `--oss-root` 和 GitHub Actions 环境；正式发布还需要凭据配置并使用生产组，演练使用独立组和签名私钥，不获取 OSS 写入凭据。开发测试不要调用真实通道。公钥固定在 `scripts/update_public_key.pem`，测试校验它与客户端内置公钥一致，不能从待验证文件里获取信任根。

## 5. 移动端发布边界

Android 当前只发布 `arm64-v8a` APK。Release 工作流会使用调试证书签名，因此文件名会标记为 `debug-signed`：可用于真机侧载测试，但不是 Google Play 可提交的正式签名包。安装前需在 Android 系统中允许该来源安装未知应用。iOS 项目、媒体和导出可构建，但本地分析仍需要 Rust 静态库、ONNX Runtime XCFramework 和 Runner 链接；没有这些产物时不要发布为完整 AI 分析版本。

移动端构建入口见 [`architecture/MOBILE_RUNTIME_V1.md`](architecture/MOBILE_RUNTIME_V1.md) 和 [`../apps/mobile/README.md`](../apps/mobile/README.md)。

## 6. 版本与变更记录

发布前：

1. 更新根目录 [`CHANGELOG.md`](../CHANGELOG.md)；
2. 在 README 中明确版本和限制；
3. 协议或数据库变化时更新架构文档和兼容说明；
4. 算法参数变化时新增带日期的基准记录；
5. 为源码和二进制分别列出内容，不把模型默认为源码的一部分；
6. 使用可追溯的 Git commit 或 tag。

没有真实发布物和测试证据时，不要创建“稳定版”或“已支持全部平台”的 Release。

## 7. 当前发布阻塞项

依据 [`OPEN_SOURCE_AUDIT.md`](OPEN_SOURCE_AUDIT.md)，以下事项仍需在正式稳定版前完成：

- 清理或核验当前源码树中的其他模型、原生二进制、研究 checkout 和截图；
- 逐项生成锁定依赖的许可证 notices；
- 确认模型权重和训练数据授权；
- 使用公开授权的演示视频和截图；
- 在无仓库、无 Homebrew、无开发 `.venv` 的机器上验证；
- 完成 macOS 签名、公证和 Gatekeeper 验证；
- 完成 Windows 安装包和移动端目标设备验证。
