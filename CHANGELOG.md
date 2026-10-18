# 变更记录

格式参考 [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)，版本遵循语义化版本约定。

## [Unreleased]

### Fixed

- 修复审核视频铺满布局：解除外层尺寸限制并显式启用覆盖缩放，让视频和标注使用同一裁剪坐标空间；
- 修复 macOS 构建机制作 DMG 时偶发 `Resource busy`：关闭临时构建机索引、显式采用 HFS+，仅对资源占用有限重试，并验证镜像完整性；
- 修复 Windows 随包 FFmpeg 不含 `libx264` 时的片段导出与合并重新编码失败，依次尝试可用的 H.264 编码器和高质量 MPEG-4；
- 修复 Windows 引擎未直接查找运行时目录中 `ffmpeg.exe`、`ffprobe.exe` 的问题，打包前增加真实代理与导出检查；
- 更换返回 HTTP 410 的 macOS Intel FFmpeg 下载地址，并校验下载二进制的摘要、架构与可执行性；
- 移除两个视频制作脚本中的开发机绝对路径，支持通过环境变量指定素材与剪映草稿目录。

### Added

- 增加中英文根 README、入门、FAQ、开发和发布入口；
- 增加文档任务索引、模型/数据授权说明、第三方 notices 和开源审计记录；
- 增加源码树公开前检查脚本；
- 增加模型、数据、标签和截图目录的本地使用说明。

### Changed

- 将 macOS 打包说明合并到 `docs/RELEASE.md`；
- 将第三方许可证研究信息合并到 `docs/THIRD_PARTY_NOTICES.md`；
- 将单样本分析基准移动到 `docs/benchmarks/`，与用户运行文档分开；
- README 明确桌面端、Android 和 iOS 当前实现边界，不把移动端或二进制发布写成已完成。

### Known limitations

- 当前不是包含 Python、FFmpeg、模型和原生 Runtime 的最终用户安装包；
- 模型权重、训练数据、真实比赛视频、截图和原生二进制仍需独立核验授权；
- macOS/Windows 分发、iOS 本地分析和移动端真机验收仍未完成。
