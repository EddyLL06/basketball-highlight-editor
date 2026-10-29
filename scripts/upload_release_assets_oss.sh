#!/usr/bin/env bash
set -euo pipefail
cat >&2 <<'MESSAGE'
本地同步入口已关闭：它无法取得跨 workflow 的生产通道锁。
请使用 GitHub Actions 的 BHE release packages（publish_oss=true）
或 Upload existing release assets to OSS，按标签选择平台。
本地验证请运行 scripts/publish_release_update.py --store-dir <临时目录>，使用测试密钥。
MESSAGE
exit 2
