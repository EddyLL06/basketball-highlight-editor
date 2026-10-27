# 开发指南

**中文** · [English](DEVELOPMENT.en.md)

这份文档面向修改代码、协议、算法或 UI 的贡献者。先阅读根目录 [`CONTRIBUTING.md`](../CONTRIBUTING.md)，再按变更范围阅读产品契约和架构文档。

## 1. 开发环境

推荐：

- macOS Apple Silicon 或 Intel；
- Python 3.11；
- Flutter stable（当前开发基线为 3.44.8）；
- FFmpeg/FFprobe；
- 本地、已确认授权的模型和测试视频；
- Git。

创建 Python 环境：

```bash
python3.11 -m venv .venv
.venv/bin/python -m pip install --upgrade pip
.venv/bin/python -m pip install -r requirements-dev.txt
```

准备桌面 Flutter：

```bash
cd apps/desktop
flutter pub get
```

移动端依赖：

```bash
cd apps/mobile
flutter pub get
```

本地模型、视频、标注、截图和构建产物不应进入 Git；目录约定见 [`../models/README.md`](../models/README.md)、[`../data/README.md`](../data/README.md) 和 `.gitignore`。

## 2. 代码边界

```text
apps/desktop/                 Flutter 桌面 UI 和项目状态
apps/mobile/                  独立 Flutter 移动端
packages/bhe_core/            移动端共享模型、项目包和引擎接口
packages/bhe_runtime/         Rust/ONNX 移动端原生 Runtime
engine/python/                JSONL Engine、任务和存储适配
engine/python/adapters/       算法脚本和导出适配
src/basketball_highlight/     检测、事件、轨迹和审核规则
scripts/                      分析、导出、运行时和移动端构建脚本
docs/architecture/            架构、协议和数据库契约
design-system/                UI 设计规范
tests/                        Python 测试
apps/desktop/test/            桌面 Flutter 测试
apps/mobile/test/             移动 Flutter 测试
```

关键约束：

- 桌面 UI 不直接操作 SQLite、检测 JSON 或 FFmpeg；
- 桌面 Engine 通过 JSONL 协议提供能力；
- 移动端不启动桌面 Python Engine，通过平台 channel 调用媒体和原生 Runtime；
- 数据库保存事实状态，中间视频和检测文件位于用户项目的 `artifacts/`；
- 原始视频默认只引用，不复制、不移动、不自动删除；
- 导出以数据库当前审核状态为准，不信任 UI 缓存；
- 新分析成功切换前不能清空旧候选；
- 协议或数据库变更前，先更新契约文档和测试。

## 3. 推荐工作流

### 3.1 先确认工作树和调用链

```bash
git status --short --branch
git diff --stat
rg -n "command_name|handler_name|table_name" apps engine src scripts tests
```

先确认是否有其他 Agent 或开发者的未提交修改。不要覆盖、格式化、重置或删除无关改动；需要隔离工作时使用独立 worktree。

### 3.2 先写验收，再改实现

每个功能或 Bug 先记录可复现输入、预期输出和失败边界。Python 逻辑优先在 `tests/` 增加最小测试；Flutter 交互优先覆盖状态变化、按钮禁用和错误反馈。

### 3.3 保持小提交

```bash
git add path/to/changed/files
git diff --cached --check
git commit -m "docs: update runtime guide"
```

不要把视频、模型、构建目录、`.venv`、截图或本机绝对路径加入提交。

## 4. 测试命令

源码公开前检查：

```bash
python3 scripts/check_open_source.py
```

Python：

```bash
.venv/bin/python -m pytest -q
.venv/bin/python -m pytest -q tests/test_engine.py tests/test_export_adapter.py
```

桌面 Flutter：

```bash
cd apps/desktop
flutter analyze
flutter test
flutter build macos --debug
```

移动 Flutter：

```bash
cd apps/mobile
flutter analyze
flutter test
flutter build apk --debug
```

真实视频分析、Android/iOS 原生库、模型输出和最终导出仍需要目标平台手测；单元测试不能替代这些验收。

## 5. 调试桌面分析链路

```text
validate_input
→ prepare_proxy
→ coarse_scan
→ generate_candidates
→ refine_candidates（标准模式）
→ verify_rim_crossing（标准模式，篮筐逐帧复核）
→ persist_candidates
→ prepare_review_previews
→ completed
```

脚本帮助：

```bash
.venv/bin/python scripts/create_proxy.py --help
PYTHONPATH=src:scripts .venv/bin/python scripts/scan_video.py --help
.venv/bin/python scripts/generate_candidates.py --help
.venv/bin/python scripts/refine_dynamic_candidates.py --help
.venv/bin/python scripts/verify_rim_crossing.py --help
```

这些脚本的 `--help` 不会验证真实视频、模型和 ROI；调试输出写到临时目录，不要写入仓库或提交到 Git。

## 6. 分析模式变更

快速/标准模式不是两个独立产品，必须保持：

- 审核、手动范围、保留/排除和导出语义一致；
- 缓存键包含视频指纹、代理参数、模型和算法版本；
- 分析批次保存实际参数快照和阶段耗时；
- 新批次失败或取消时旧结果仍可用；
- 快速模式不能通过限制候选数量制造提速；
- 速度、召回和错误类型要用固定视频分别测量。

修改参数后，新增带日期的基准记录，并同步 [`research/ANALYSIS_MODES_V1.md`](research/ANALYSIS_MODES_V1.md)。不要把单样本耗时写成普遍保证。

## 7. UI 修改

桌面 UI 以 [`../design-system/courtside/MASTER.md`](../design-system/courtside/MASTER.md) 为设计源。改动审核工作台时优先保证：

- 视频区域占主要空间；
- 候选切换、播放和审核状态有清晰反馈；
- 导出锁定状态可理解；
- 响应式窗口下不遮挡视频和时间轴；
- 键盘焦点、减少动效和浅色/深色主题可用。

视觉改动请附已确认可以公开的截图；不要提交含本机路径、真实球员或真实比赛视频的截图。

## 8. 协议、数据库和移动 Runtime 变更

修改 Engine 命令时同步：

1. [`architecture/ENGINE_PROTOCOL_V1.md`](architecture/ENGINE_PROTOCOL_V1.md)；
2. Engine handler 和 Flutter client；
3. 协议测试与错误路径测试；
4. 版本兼容说明。

修改 SQLite 时同步：

1. [`architecture/SQLITE_SCHEMA_V1.sql`](architecture/SQLITE_SCHEMA_V1.sql)；
2. storage 初始化和读写逻辑；
3. 旧项目、空值和迁移测试；
4. [`architecture/PROJECT_LAYOUT_V1.md`](architecture/PROJECT_LAYOUT_V1.md) 的生命周期说明。

修改移动端 channel、Rust C ABI、ONNX 输入输出或 ABI 时同步 [`architecture/MOBILE_RUNTIME_V1.md`](architecture/MOBILE_RUNTIME_V1.md)、Android/iOS 构建说明和目标平台测试。

## 9. 本地手工打包与 DirectML 常见坑

### 9.1 不要手工拼 runtime 目录

`runtime/` 的完整清单由 [`../scripts/prepare_windows_runtime.ps1`](../scripts/prepare_windows_runtime.ps1) 定义（`engine/python`、`scripts`、`src`、`models/bball_model.pt`、`docs/architecture/SQLITE_SCHEMA_V1.sql`、`bin/ffmpeg.exe`、`bin/ffprobe.exe`）。**按记忆列举目录一定会漏**，漏掉 `docs/architecture/SQLITE_SCHEMA_V1.sql` 时表现是：

```text
FileNotFoundError: ...\runtime\docs\architecture\SQLITE_SCHEMA_V1.sql
create_project failed: {"code":"FILE_NOT_FOUND", ...}
```

界面上提示「找不到文件或文件夹」并显示 `runtime` 下的路径，容易误判成视频路径问题。正确做法是直接跑官方脚本，或改完后用它生成：

```powershell
powershell -File scripts\prepare_windows_runtime.ps1 -PythonRuntime <含 python.exe 的目录> `
  -Ffmpeg <ffmpeg.exe> -Ffprobe <ffprobe.exe> -OutPath dist\windows-runtime
```

手工组装后至少按清单逐项 `Test-Path` 核对，并用一次 `create_project` + `open_project` 冒烟验证。

### 9.2 `runtime/` 放在 Release 目录会让增量构建失败

`flutter build windows` 的 install 步骤会清理 `build\windows\x64\runner\Release`，如果手工放进 `runtime\` 且 App 正在运行，会出现 `MSB3073` / `cmake_install.cmake` 失败。先关掉 App 再构建，或把 runtime 放到构建目录之外。

### 9.3 onnxruntime 与 onnxruntime-directml 不能共存

两个 wheel 都装 `onnxruntime/` 包，同目录会互相覆盖，Python 会加载版本号更高的那个。**结果是请求 `dml` 时静默回落到 CPU，不报错**，只是日志里 `coarse_scan device=cpu`，看起来「加速没效果」。

确认方法：

```powershell
.venv\Scripts\python.exe -c "import onnxruntime as ort; print(ort.__version__, ort.get_available_providers())"
# 必须出现 DmlExecutionProvider，且版本与 onnxruntime-directml 一致
```

若同时存在两个 `dist-info`，先 `pip uninstall onnxruntime onnxruntime-directml`，再只装 `onnxruntime-directml`。注意 `ultralytics[export-base]` 会把普通 `onnxruntime` 装回来，装完要复查。

### 9.4 不要用 PYTHONPATH 注入 DML 包

[`../apps/desktop/lib/core/engine_client.dart`](../apps/desktop/lib/core/engine_client.dart) 启动引擎时是**覆盖**而非追加 `PYTHONPATH`：

```dart
environment['PYTHONPATH'] = enginePythonPath;
```

所以把 `onnxruntime-directml` 装到临时目录、再用 `PYTHONPATH` 指过去不会生效，引擎子进程看不到。加速包必须装进引擎实际使用的解释器环境（`BHE_PYTHON` 指向的那个）。

### 9.5 确认加速是否真的生效

看 `%LOCALAPPDATA%\BHE\logs\engine.log` 里分析完成行：

```text
coarse_scan device=dml          # 生效
coarse_scan device=cpu          # 回落到 CPU，检查 9.3 / 9.4
```

DML 必须单张推理（`BACKEND_MAX_BATCH["dml"]=1`），批量喂反而更慢，这是后端特性不是 bug。

### 9.6 手机竖拍视频的画面方向

手机竖着拍的视频，编码出来的帧是 720×1512，转正角度写在 MP4 容器里
（`rotation` side data）。ffmpeg 命令行默认会读它并自动加 `transpose`，所以
引擎抽帧、生成代理都是正的；但 **media_kit 在 Windows 软件渲染路径下不应用
这个旋转**，送出的纹理还是竖的。

症状：画面被塞进按显示方向算好的横框里，看着像「放大了、只看到球场一块」，
严重时像被裁成左右两截。数据层看不出问题——库里存的 `1512×720` 是对的。

处理方式：

- `inspect_video` 把 `rotation` 一起返回并存进 `videos.rotation`（加列之前
  的项目在 `open_project` 时只补字段，不动 ROI 和候选）；
- 前端用 `OrientedVideo` 在 Windows 上自己转纹理，其它平台交给播放器。

排查时先确认三件事：`ffprobe` 的 `rotation`、库里存的宽高、UI 实际渲染的框
比例。三者不一致时按上面这条链依次核对。

### 9.7 分析引擎运行库初始化失败（torch / ONNX Runtime）

Windows 上 `torch` 的 `c10.dll` 或 ONNX Runtime（ORT，另一条模型推理路径）的
`onnxruntime_pybind11_state` 可能报 `ImportError` / `OSError`、DLL 加载失败或
WinError 1114。torch 不可用时 CPU 会尝试已有的 ONNX 模型；**ORT 也无法加载时，
兜底不能解决问题**。DLL 文本不能单独证明是 CPU、VC++ 运行库还是安全软件导致。

分析现在先进入 `engine_preflight`（检查分析引擎），在独立子进程中使用真正分析的
解释器与 `select_device → load_detector` 路径验证加载，明确失败才阻止生成代理视频。
错误码为 `ENGINE_RUNTIME_UNAVAILABLE`，界面首行提示 Windows 用户安装最新的
[VC++ x64 运行库](https://aka.ms/vs/17/release/vc_redist.x64.exe)并重启，仍失败时提供
CPU 型号和 BHE 诊断信息；macOS/Linux 使用不含 VC++ 的通用提示。原始异常链保留
在后续行及日志，自动 ROI 检测使用同样的检查与错误提示。

自检成功按“请求设备 + 主模型真实路径 + 大小 + 修改时间”缓存在当前引擎会话中，
自动 ROI 和分析可复用；不跨重启保存。**自检 300 秒超时、无诊断的崩溃、无法解析
输出或无法启动检查子进程均只记 warning、放行且不缓存**，让真正分析继续判断。
取消仍然取消任务。自检只证明模型可加载，不保证后续显存、驱动及真实输入都正常。

Windows 的 `[bhe] environment ...` 行新增：

```text
avx=true avx2=true avx512f=false msvcp140=14.42.34433.1
```

- `avx` / `avx2` / `avx512f`：Windows 报告的 CPU 指令能力；`unknown` 表示无法读取，
  不是“不支持”。[微软文档](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-isprocessorfeaturepresent)
  和 [SDK 头文件](https://github.com/microsoft/win32metadata/blob/main/generation/WinSDK/RecompiledIdlHeaders/um/winnt.h)
  的常量分别为 39、40、41；这些探测项从 Windows 10 2004 / build 19041 起支持，
  更早系统记录 unknown。不能仅凭 false 判定裸硬件一定缺少该指令，也不因此禁用分析。
- `msvcp140`：通过系统目录 API 定位 System32 中的 `msvcp140.dll`，读取其四段文件
  版本；unknown 表示文件/API 不可读。此字段不代表程序实际加载的 DLL 路径，也不
  代表已确定根因。依据版本查询的 [GetFileVersionInfoW](https://learn.microsoft.com/en-us/windows/win32/api/winver/nf-winver-getfileversioninfow)
  与 [VerQueryValueW](https://learn.microsoft.com/en-us/windows/win32/api/winver/nf-winver-verqueryvaluew)。
- 这些字段仅在 Windows 出现，单项探测失败不影响其它字段，更不影响引擎启动。

排查顺序：保留错误原文与整条 environment 行；核对 CPU 型号、系统版本、上述能力
和系统运行库版本；安装/修复 VC++ 后重启再试；仍失败时检查安全软件是否拦截，或
用英文短路径重新安装。不要把某个字段直接当作唯一根因。

可用发布包自带解释器分别验证，避免误用系统 Python：

```powershell
& "<runtime>\python\python.exe" -c "import torch; print(torch.__version__)"
& "<runtime>\python\python.exe" -c "import onnxruntime as ort; print(ort.__version__)"
```

## 10. 提交前检查

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
git status --short --branch
```

确认：

- [ ] 所有修改文件为 UTF-8，无 BOM；
- [ ] 没有视频、数据、模型、截图、密钥或构建产物；
- [ ] 没有 `/Users/...`、`/home/...` 或 Windows 个人绝对路径；
- [ ] 文档命令与实际目录、脚本参数一致；
- [ ] 中英文入口已同步；
- [ ] 协议、数据库、移动 Runtime 或许可证影响已记录。

## 11. 提交问题和 PR

Bug 报告至少包含版本/commit、系统、运行方式、最小复现步骤、实际结果和预期结果。不要附带未脱敏视频、密钥、个人路径或包含球员个人信息的素材。
