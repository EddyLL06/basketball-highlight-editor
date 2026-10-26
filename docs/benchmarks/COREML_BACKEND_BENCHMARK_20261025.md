# CoreML 推理后端基准记录（2026-10-25）

> 历史实验记录：路径、模型和设备只代表当时的本地环境，不是当前仓库的可复现输入，也不是准确率或耗时承诺。

## 目的

macOS 桌面端目前用 ultralytics/torch + `mps` 跑检测。本次新增可选后端 `coreml`：把同一份模型导出成静态
ONNX，交给 ONNX Runtime 的 CoreML Execution Provider 走 Apple 的 Metal 后端。需要回答三件事：

1. 端到端（粗扫 → 精筛 → 复核三段）快多少，是否达到 ≥10% 的放量门槛；
2. 检测结果与现状是否等价；
3. 代价是什么（分发体积、默认行为变化）。

## 输入与配置

| 项目 | 值 |
|---|---|
| 机器 | Apple M2 / 8 GB，macOS 27.0.1 |
| 源视频 | `test-video.MOV`（1920×1080 HEVC 30 FPS，357.8 s） |
| 代理视频 | `X23.mp4`（960×540 H.264 5 FPS，1789 帧） |
| 模型 | `models/bball_model.pt` |
| 静态模型 | `models/bball_model.static.onnx`（12.2 MB，输入 `1×3×640×640`，输出 `1×6×8400`，opset 18） |
| 臂 A（现状） | `--device mps`，torch 2.14.1 + ultralytics 8.4.184 |
| 臂 B（本次） | `--device coreml`，onnxruntime 1.31.0，`MLProgram` + `MLComputeUnits=CPUAndGPU` + `SpecializationStrategy=FastPrediction` |
| 粗扫 | 代理、`sample-fps=5`、`--scale 4`（按裁切尺寸钳制后实际 1.2098）、`conf=0.10`、ROI `[380, 8, 909, 413]`（529×405） |
| 精筛 | 源视频、`sample-fps=10`、`--scale 2`（实际 1.0）、`window=2.5s`、`conf=0.10`、ROI `[760, 16, 1818, 826]`（1058×810） |
| 复核 | 源视频、`batch=16`（coreml 固定 1）、候选自带篮筐位置 |
| 缓存 | 两臂都**完全关闭缓存**（`--cache-dir` 不传），比"全新缓存目录"更严格 |

关键点：`device` 不进粗扫缓存键，两臂若共用缓存会直接命中旧结果、把一次 A/B 测成 0 秒，所以两侧必须彻底冷跑。

## 结果（端到端，同一素材同一 ROI）

| 阶段 | 臂 A `mps` | 臂 B `coreml` | 变化 |
|---|---:|---:|---:|
| 粗扫（1789 帧） | 35.91 s | 23.09 s | **−35.7%** |
| 生成候选 | 0.17 s | 0.12 s | −0.05 s |
| 精筛（24 候选） | 34.87 s | 27.87 s | **−20.1%** |
| 篮筐复核（24 候选） | 28.27 s | 18.10 s | **−36.0%** |
| **合计** | **99.22 s** | **69.18 s** | **−30.04 s（−30.3%）** |

臂 A 在本机另外跑过两次，合计 97.2 s / 101.7 s，方差约 ±2%，所以 −30% 不是单次抖动。

### 收益来源

把每个阶段的墙钟时间和脚本自己记录的 `elapsed_seconds`（进程内、不含启动与模型加载）相减：

| 阶段 | 臂 A 启动+加载 | 臂 B 启动+加载 | 差 |
|---|---:|---:|---:|
| 粗扫 | 4.06 s | 0.76 s | −3.30 s |
| 精筛 | 0.53 s | 0.13 s | −0.40 s |

约 **3.7 s 来自进程启动与模型加载**（两段合计，占总收益 12%），**其余约 26 s 来自每帧开销**。粗扫的每帧成本从
17.8 ms 降到 12.5 ms（1789 帧分母确定）。

单帧前向对照（24 帧、取 3 次最小值、含预处理与 NMS）：

| 场景 | torch/MPS | CoreML `CPUAndGPU` | 比值 |
|---|---:|---:|---:|
| 粗扫 529×405 | 8.69 ms | 10.08 ms | 0.86× |
| 精筛 1058×810 | 8.30 ms | 9.03 ms | 0.92× |
| 复核 340×340 | 11.05 ms | 8.87 ms | 1.25× |

这张表说明**收益不来自前向本身**：粗扫、精筛两组裁切上 CoreML 的单帧前向甚至略慢，只有复核的小裁切更快。
端到端仍然快 30%，差值落在 torch 路径的每帧固定开销上（ultralytics 预处理、MPS 上的 NMS 与同步、批处理摊销）。
看到"单帧快 1.4 倍"就推算端到端会算错方向，这里的结论必须以端到端为准。

## 等价性

| 项 | 门槛 | 实测 | 结论 |
|---|---|---|---|
| 后端真的生效 | providers 含 `CoreMLExecutionProvider` | 粗扫/精筛脚本自报 `device=coreml`；单帧探测 `provider=CoreMLExecutionProvider`、输入 `(1,3,640,640)` | 通过 |
| 粗扫记录数 | 完全一致 | 1789 = 1789 | 通过 |
| 逐帧检测数量 | 完全一致 | 1789/1789 帧一致，0 帧数量不同 | 通过 |
| 框配对（IoU ≥ 0.5） | 全部配对 | 2907 / 2907，0 个未匹配 | 通过 |
| 公共帧平均 IoU | ≥ 0.99 | **0.9999**（最低 0.9557） | 通过 |
| 置信度最大差 | ≤ 0.02 | **0.0000** | 通过 |
| 粗扫候选数 | 完全一致 | 24 = 24 | 通过 |
| 候选时间与 verdict | 逐条一致 | 24/24 配对，无缺失、无 verdict 差异 | 通过 |
| 精筛 refined 条数 | 完全一致 | 19 = 19 | 通过 |
| 精筛 verdict 分布 | 完全一致 | `ambiguous×18 + made×1` 两侧相同 | 通过 |
| 复核 status 分布 | 完全一致 | `rejected×9 / skipped×5 / made×10` 两侧相同 | 通过 |
| 复核 reason | 逐候选一致 | 0 处不同 | 通过 |
| 最终排除数 | 一致 | 0 = 0 | 通过 |

置信度最大差为 0.0000 的原因是粗扫记录里的置信度保留 4 位小数，两侧在这里已经量化到同一格。

## 体积代价

| 项 | 原始 | gzip -9（近似 dmg 压缩率） |
|---|---:|---:|
| `onnxruntime` 1.31.0（`libonnxruntime` 33.0 MB + `onnxruntime_pybind11_state.so` 40.8 MB + 其它 8.6 MB） | 80 MB | 约 22 MB |
| `models/bball_model.static.onnx` | 12.2 MB | 10.5 MB |
| **合计** | **约 92 MB** | **约 30–33 MB** |

- `torch` 与 `.pt` 必须保留：macOS 仍需要它们做 mps/cpu 回退，且静态 ONNX 就是从 `.pt` 导出的。
- `onnx` 只在构建期导出时需要，不必进运行时。`onnxruntime/tools`、`quantization`、`transformers`（约 8.6 MB）用不到。
- `onnxruntime_pybind11_state.so` 未 strip，`strip -x` 后 40.8 MB → 25.6 MB（gzip 10.8 MB → 9.2 MB），可以省约 1.6 MB 压缩体积。
- 静态模型权重是 fp32，压缩率很低；改 fp16 能砍掉一半左右，但会改变数值，不在本次范围。

## 配置约束（写死，别再试）

`MLComputeUnits` 只接受 `CPUOnly` / `CPUAndGPU` / `CPUAndNeuralEngine`，**区分大小写**。写成非法值不会报错，
ORT 会把整个 CoreML EP 丢掉、只留 CPU，症状是"看起来在加速、实际慢得多"。因此：

- 默认固定 `CPUAndGPU`（Metal），不选 `CPUAndNeuralEngine`：本轮复核裁切的对照里，小裁切走 Metal 已是最快；
- 建会话后强制断言 `get_providers()[0] == "CoreMLExecutionProvider"`，不匹配就把 `device` 降级为 `cpu`，
  决不允许"以为在加速"的情况静默通过；
- 非法取值的耗时本轮未单独量化，防御手段是上一条断言（`tests/test_onnx_detector.py` 有覆盖）。

静态 `1×3×640×640` 模型只吃方形输入、一次只能一张，所以 coreml 路径传 `letterbox_mode="square"` +
`max_batch=1`；`auto` 的默认值保持矩形 letterbox，Windows DirectML 的行为不受影响。

## 结论边界

1. **Intel Mac 未测**。发布矩阵里还有 `macos-15-intel`，本轮所有数字都来自 Apple Silicon。代码里用
   `platform.machine() == "arm64"` 把 coreml 限制在 arm64，Intel 上 `coreml_available()` 直接返回 False，
   回落 mps/cpu——宁可不用，也不要在没数据的老机型上默认变慢。
2. **单素材、单机器**。只有一段 6 分钟 1080p 素材、24 个候选，8 GB 内存；更长素材、4K、多段项目未测。
3. **两臂的输入几何是一致的**。脚本对 torch 路径一直传 `rect=False`（方形 640²），coreml 路径是显式
   `letterbox_mode="square"` + `max_batch=1`，两边送进模型的张量几何相同。所以表里最低 0.9557 的那个框
   是数值差异（CoreML 的 MLProgram 计算与 torch 不逐位一致，坐标在记录里量化到 2 位小数），不是几何差异。
   如果哪天把 torch 路径改回 `rect=True`，这条等价性结论就不再成立。
4. **缓存全关**。真实使用会带缓存，第二次分析（命中缓存）的收益比例会低于本表。
5. **实测环境**：本机宿主策略会拦截文件删除，ONNX Runtime 的 CoreML EP 在编译 mlpackage 时必须
   remove/rename 临时文件，因此这次 A/B 是在放开该限制的条件下跑的。同类环境里如果删不掉临时文件，
   CoreML 会话会直接建不起来（`filesystem error: in remove: Operation not permitted`），表现为分析直接失败
   而不是变慢——这也是保持 `coreml_available()` 用实际建会话结果兜底的原因。

## 复现

| 脚本（`.tmp/perf-audit/`） | 内容 |
|---|---|
| `p3_ab.py` | 两臂 × 三阶段端到端 A/B，输出 `ab_report.json`（含一致性比对） |
| `probe_coreml_frame.py` | provider 确证 + 三种裁切的单帧前向对照 |
| `bench_ep_matrix.py` | EP 配置矩阵与启动成本（本轮因宿主限制未跑完） |

导出静态模型：

```bash
python scripts/export_mobile_model.py \
  --model models/bball_model.pt \
  --output models/bball_model.static.onnx \
  --imgsz 640 --batch 1      # 不要加 --dynamic：动态 batch 在 CoreML 上没有收益
```
