# Windows 一键升级：真实发布包验收

CI 里的测试用的是几个文件的模拟程序，只能证明替换逻辑本身没错。**发版前必须在真实 Windows 机器上，用真实打出来的发布包（带 torch、onnxruntime、FFmpeg 的完整运行时）走一遍下面的流程。**

只测升级流程本身，不发布任何版本。测试包用 `9.9.x` 这样的假版本号，更新地址指向本机，签名用你自己生成的测试密钥，**不要用发版私钥，也不要把测试包上传到任何地方。**

## 0. 准备

- Windows 10/11 x64，Windows PowerShell 5.1（系统自带）；
- 装有 Git for Windows（它自带带 Ed25519 支持的 `openssl.exe`）；
- 仓库在最新 `main`（要包含一键升级和 `BHE_UPDATE_PUBLIC_KEY`）；已能按 `docs/DEVELOPMENT.md` 第 9 节正常打 Windows 包；
- 测试目录用中文加空格，顺带测路径兼容：`D:\测试 BHE\`；
- 磁盘留 15GB 以上（三个完整发布包加解压）。

```powershell
$work = "D:\bhe-update-test"
New-Item -ItemType Directory -Force $work, "$work\serve" | Out-Null
$ssl  = "C:\Program Files\Git\usr\bin\openssl.exe"
```

### 0.1 生成测试密钥，取出公钥

```powershell
& $ssl genpkey -algorithm ed25519 -out "$work\test.key"
& $ssl pkey -in "$work\test.key" -pubout -outform DER -out "$work\pub.der"
$der = [IO.File]::ReadAllBytes("$work\pub.der")
$pub = [Convert]::ToBase64String($der[($der.Length - 32)..($der.Length - 1)])   # 公钥是 DER 的最后 32 字节
$pub
```

### 0.2 打三个测试包 9.9.1 / 9.9.2 / 9.9.3

三个包的代码一样，只有版本号不同，更新地址和公钥通过 `-DartDefine` 烧进去：

```powershell
$defines = @("BHE_UPDATE_URL=http://127.0.0.1:8765/latest.json", "BHE_UPDATE_PUBLIC_KEY=$pub")
foreach ($v in "9.9.1", "9.9.2", "9.9.3") {
    & .\scripts\build_windows_release.ps1 -Zip -Version $v -DartDefine $defines
}
```

产物在 `dist\BHE-windows-x64-v9.9.x.zip`。每个包都要完整构建（含运行时），比较慢。

### 0.3 生成并签名更新清单（每次只让「最新版」是目标版本）

清单的说明文字从 README 的「最近更新」表里取，这里用临时文件，不动仓库：

```powershell
function Publish-Manifest($version) {
    Remove-Item "$work\serve\*" -Force -ErrorAction SilentlyContinue
    Copy-Item ".\dist\BHE-windows-x64-v$version.zip" "$work\serve\"
    $zh = "| 版本 | 日期 | 主要更新 |`n|---|---|---|`n| v$version | 2026-10-26 | 本地升级测试 |"
    $en = "| Version | Date | Highlights |`n|---|---|---|`n| v$version | 2026-10-26 | Local update test |"
    [IO.File]::WriteAllText("$work\zh.md", $zh)
    [IO.File]::WriteAllText("$work\en.md", $en)
    python scripts\build_update_manifest.py --tag "v$version" --assets-dir "$work\serve" `
        --base-url http://127.0.0.1:8765 --readme-zh "$work\zh.md" --readme-en "$work\en.md" `
        --out "$work\serve\latest.json"
    & $ssl pkeyutl -sign -inkey "$work\test.key" -rawin -in "$work\serve\latest.json" -out "$work\serve\latest.json.sig"
}
Publish-Manifest "9.9.2"
```

### 0.4 起本地更新服务器

**用系统或开发环境的 Python，不要用被测 BHE 自带的 `runtime\python`**——它放在安装目录里，会占用文件，导致替换失败。

```powershell
Start-Process python -ArgumentList "-m","http.server","8765","--directory","$work\serve" -WindowStyle Minimized
```

### 0.5 安装 9.9.1

把 `dist\BHE-windows-x64-v9.9.1.zip` 解压到 `D:\测试 BHE\`，得到 `D:\测试 BHE\BHE\BHE.exe`。打开，「关于」里应显示 `v9.9.1`。

先做点准备，后面要用：导入一个视频（最好是竖拍的 `79d0b7…mp4`）建一个项目，跑一次分析、导出一次，记下项目名和候选数。

## 1. 验收项

每项记录：通过 / 不通过，不通过时附画面截图和下面第 3 节的日志。

| # | 场景 | 操作 | 期望 |
|---|---|---|---|
| 1 | 正常更新（中文加空格路径） | 「关于 → 检查更新」，发现 9.9.2 → 下载 → 「安装并重启」 | 窗口关闭后自动重新打开（请记录从点击到重新出现用了多久）；「关于」显示 v9.9.2；`D:\测试 BHE\` 下出现 `BHE.previous-<32位十六进制>` 和同名加 `.bhe-update.json` 的文件，里面是 9.9.1；原来的项目能打开，候选数不变 |
| 2 | **更新后功能正常** | 在 9.9.2 里打开竖拍视频项目 | 审核页能播放、画面方向正确；能再跑一次分析；能导出 |
| 3 | **用过之后再更新**（重点） | 先 `Publish-Manifest "9.9.3"` 换清单；在 9.9.2 里**先做一次分析和一次导出**，再更新到 9.9.3 | 成功。若失败并提示 `Extra file found: runtime/...`，说明运行时在安装目录里生成了清单外的文件（比如 `__pycache__`），这是阻断问题 |
| 4 | 只保留最近一份旧版 | 第 3 项完成后看 `D:\测试 BHE\` | 只剩 `BHE.previous-*` **一份**（9.9.2），9.9.1 那份已被自动删除，对应的 `.bhe-update.json` 也没了；`cleanup.log` 里有 `Removed older backup` |
| 5 | 分析或导出进行中 | 开始一次分析，同时打开更新弹窗 | 「安装并重启」按钮不可点，提示「请等待当前操作结束后再安装更新」；取消分析后按钮恢复可点 |
| 6 | 安装目录混入个人文件 | 在 `BHE\` 里新建一个 `notes.txt`，点「安装并重启」 | 安装前就失败，提示 `Extra file found: notes.txt`；BHE **不关闭**、能继续用；版本没变、没有出现 `.previous-*`；删掉 `notes.txt` 后能正常安装 |
| 7 | 失败后引擎恢复 | 第 6 项失败后，不重启 BHE，直接导入视频、开始分析 | 能正常分析（引擎被自动恢复） |
| 8 | 文件被占用，替换失败 → 自动恢复 | 另开一个 PowerShell 执行 `$h = [IO.File]::Open("D:\测试 BHE\BHE\runtime\bin\ffmpeg.exe",'Open','Read','Read')`（保持不关），再点「安装并重启」 | BHE 关闭后又自动打开**旧版本**，并弹出「BHE update failed」对话框，写明旧版目录路径；`D:\测试 BHE\BHE\` 还是旧版、能正常用；关闭那个句柄（`$h.Dispose()`）后再更新能成功 |
| 9 | 清单被篡改 | 编辑 `serve\latest.json` 随便改一个字，不重新签名；「检查更新」 | 提示校验失败，**不显示**有新版本 |
| 10 | 安装包被篡改 | 重新 `Publish-Manifest "9.9.2"`，然后用十六进制工具改 `serve` 里 zip 的一个字节；下载 | 提示 SHA-256 校验失败，不进入安装 |
| 11 | 杀毒软件 | Defender 实时保护开着，另外有 360 或火绒的话也开着，重复第 1 项 | 能成功更新；新的 `BHE.exe`、更新助手没有被拦截或隔离（若被拦，记录是哪个软件、拦了哪个文件） |
| 12 | 准备阶段不能强行关闭 | 点「安装并重启」后，转圈准备期间点窗口的关闭按钮 | 窗口不被关掉，等准备结束；准备完成后才关闭并更新 |
| 13 | 项目数据不受影响 | 比较更新前后同一个项目 | 项目列表、候选、审核结果、导出历史都在 |

## 2. 清理

```powershell
Stop-Process -Name python -ErrorAction SilentlyContinue   # 只在确认没有别的 Python 任务时
Remove-Item "D:\测试 BHE" -Recurse -Force
Remove-Item $work -Recurse -Force
```

测试密钥和测试包不要提交到仓库，也不要保留公钥以外的任何测试产物。

## 3. 出问题时要带回的信息

- 失败的项目编号、画面截图；
- 更新会话目录里的这几个文件：`%LOCALAPPDATA%\BHE\updates\install-*\`
  - `status.json`（失败发生在哪个阶段、涉及哪些目录）
  - `error.txt`（失败原因）
  - `cleanup.log`（清理旧备份的结果）
- 「关于 → 发送反馈」复制出来的诊断信息；
- 如果更新后 BHE 打不开：`D:\测试 BHE\` 下有哪些目录，旧版目录里的 `BHE.exe` 还在不在。

## 4. 结论格式

请按下面格式回复，一项一行：

```
1 通过
2 通过
3 不通过：提示 Extra file found: runtime/engine/python/...（附日志）
...
```

任何一项不通过都先不要发版。
