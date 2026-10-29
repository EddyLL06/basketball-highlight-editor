# 手机随机与交错回归

从 `apps/mobile` 运行（使用项目已有 Flutter SDK）：

```sh
# 默认每个随机循环 30 个种子；固定复现也会运行
flutter test --no-pub --concurrency=1 test/regression

# 发版前：每个随机循环 300 个种子
BHE_FUZZ_SEEDS=300 flutter test --no-pub --concurrency=1 test/regression
```

`BHE_FUZZ_SEEDS` 是统一的正整数种子数量，设置后覆盖各套旧的 `*_COUNT` 参数；未设置时旧参数仍可用，否则默认为 30。每个随机循环都使用固定种子及固定偏移，输出汇总与失败种子；失败时还打印首个失败的场景和操作轨迹。某些套件可通过其原有 `*_RESULT` 环境变量写出完整 JSON 结果，默认不写结果文件。

复现时选择输出中的失败测试文件并重跑同一范围。例如批次测试的种子 17：

```sh
BHE_FUZZ_SEEDS=1 P6_BATCH_START=17 flutter test --no-pub --concurrency=1 test/regression/export_batch_cleaned_fuzz_test.dart
```

其他支持指定起点的参数：`BHE_FUZZ_SEED`（项目模型）、`BHE_BARRIER_SEED`（项目屏障，默认起点 10000）、`BHE_TRANSITION_SEED`（切换准备，默认起点 20000）、`P2A_COMMIT_START`、`P2A_INTERLEAVE_START`、`P2A_START_SEED`、`P6_SEQUENCE_START`、`P6_EXCLUSION_START`、`FINAL_CANCEL_START`。未列出起点参数的套件从 0 开始，可设置 `BHE_FUZZ_SEEDS` 为失败种子加 1 并运行该文件。多个随机循环的文件也会运行同文件内的其他固定测试。

| 套件 | 保护的行为 |
| --- | --- |
| `p1b_model_fuzz_test` | 审核修改管道、撤销和写盘失败的参考模型 |
| `p1b_barrier_fuzz_test` | 写盘与打开、新建、导入、删除和分析的屏障 |
| `p1b_transition_fuzz_test` | 文件选择等异步准备阶段的切换意图顺序 |
| `p2a_roster_commit_interleaving_test` | 名单已进入写盘时的取消、切换、换视频及审核保留 |
| `p2a_roster_queue_fuzz_test` | 名单排队时取消、组失效、视频与项目变更 |
| `p2a_group_model_fuzz_test` | 分组、默认组、偏好故障恢复及串行写入 |
| `export_preflight_fuzz_test` | 导出校验、取消与重复点击准入 |
| `analysis_cancel_fuzz_test` | 模型准备和分析取消；旧线程未确认退出时重试先被拒绝 |
| `export_dynamic_fuzz_test`、`export_sequence_fuzz_test` | 切项目和导出全局准入的逐步交错 |
| `export_uncertain_fuzz_test` | 未确认停止查询和原生释放回执 |
| `export_batch_cleaned_fuzz_test` | 旧批次冻结；原生登记确认 `cleaned` 后放行、迟到回执不影响新任务 |
| `export_committed_fuzz_test` | 成品已提交后迟到回执、完成记录和合并数 |
| `heavy_task_exclusion_fuzz_test` | 分析、导出与未确认任务之间的互斥及恢复 |
| `analysis_cancel_switch_fuzz_test` | 分析取消、首条进度、切项目、迟到结果和诊断观察 |

同路径及不同项目切换的两条固定导出复现保留在 `test/features/export/`，与 gpt2 的适配版一致，未重复复制。历史“等待旧 Dart 回执才放行”的批次测试和旧版分析取消重试假设不适用当前契约，未纳入。测试使用可控的模拟平台通道，不替代 Android 真机媒体和线程验收。
