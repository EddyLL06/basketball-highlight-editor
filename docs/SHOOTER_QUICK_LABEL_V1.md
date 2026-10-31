# 射手快标 / Shooter quick labeling

桌面端审核包含「进球审核」和「射手快标」，默认进入进球审核。

1. 分析视频后，进入「射手快标」。已有项目缺少画面时可用「补齐/刷新画面」。
2. 每张卡片默认显示中间帧，可切换前后帧或「显示全景蓝框」，必要时点「看视频」。
3. 点击球员姓名立即保存射手；每张卡片都可「添加球员」。数字 1–9 标记当前卡片。
4. 可标记「不确定」、清除或撤销上一次标注。射手与进球判断、片段取舍及备注独立。

画面直接复用现有低分辨率代理和篮球轨迹，不增加人物检测或额外球检测。
标准分析期间会显示只读预览；成功后正式候选与出手画面一起保存。失败或取消保留原数据。
出手区域和时间为近似估计，遮挡或轨迹缺失时应查看相邻帧、全景或视频。
已有球员标签及人工选帧会保留；图片位于项目目录中，应与源视频一起私密保存。

本版提供半自动标注，自动识别出手者的下一版正在开发中。

The desktop Review module opens Basket review by default. Select Shooter quick label
to label candidates from stills. Five portrait cards fit a desktop row; each defaults
to its middle frame and offers adjacent frames, full context and Watch clip.
Click a name to save, use Add player on any card, or press 1–9 for the selected card.
Uncertain, Clear and Undo operate independently from basket decisions and notes.
Existing projects can use Refresh stills; new analysis prepares them automatically
from its cached proxy and ball trajectories without additional detector inference.
Drafts are read-only. Failed or cancelled preparation preserves committed data.
Release regions are approximate; review ambiguous cases in video. Automatic shooter
recognition is being developed for a later version.

## 可选人物候选接口（开发中）

桌面界面仍使用上述半自动流程。Engine 调用 `prepare_shooter_review` 时可显式传入
`person_detection: true`，仅对每个候选默认中间帧的出手区域检测人物。
输入严格复用与源视频指纹及裁剪偏移匹配的分析代理；代理缺失时报
`PERSON_PROXY_REQUIRED`，不会改用原画推理。检测输入默认 320，区域无人物时只扩大
1.2 倍重试一次，超过半帧面积预算或仍无人物则留给人工，不扫描整帧。

直接观察到球上升轨迹、且出手点不靠画面左右边缘时，人物搜索范围可缩至最多画面宽度
28%、高度 66%，并限制在原出手区域内。反推轨迹、边缘位置或无效出手点保留原区域。
这是保守的搜索规则，不是射手置信度；蓝框参考画面仍保持较宽上下文。
实际策略写入 `person_detection.search_policy`，仍遵守一次小幅重试的上限。

此接口需本地提供 `yolo11n.pt`（`BHE_PERSON_MODEL` 或运行目录的 `models/yolo11n.pt`），
SHA-256 为 `0ebbc80d4a7680d14987a577cd21342b65ecfd94632bd9a8da63ae6417644ee1`。
模型在 Engine 会话中复用；缺失或校验失败时任务失败并保留原证据及人工标签。
运行时不下载模型，当前安装包也不附带它。

`list_shooter_review` 的中间帧可含 `people`：`id`、源画面坐标 `bbox`、代理人物裁剪
`crop_path`、人物检测 `confidence`、几何距离 `release_distance` 及区域边缘提示。
编号仅在该候选、生成批次和帧内有效，不是跨片段 Track ID。
`person_detection` 记录代理尺寸、推理区域、尝试次数和耗时。
人物检测置信度和几何排序均不表示射手或姓名已确认。

人工保存仍需项目内的 `player_id`；`set_candidate_shooter` 可额外附带当前
`generation`、`time_ms` 对应的 `person_id`，错误批次或帧会被拒绝。
Made / Missed、片段取舍与备注保持独立。参考图关联姓名属于后续阶段。

实验模块 `release_shooter.py` 可从同一代理时间线的球观测拟合飞行轨迹，再结合区域人物的
上半身接触与球分离证据，返回片段内的射手编号。近旁人物难以区分、球轨迹或离手证据
不足时返回 `unknown`；评分为启发式证据强度，不是校准概率。编号不跨片段复用，不读取
姓名、参考图或旧射手标签。此模块尚未默认接入桌面分析，人工审核独立于模型预测保存。

对于第一轮 `unknown`，实验调用方可在同一代理上用两块有重叠的区域补找球，仍用现有
640 球模型输入；人物检测范围不随之全幅扩大。`fit_ball_flight(expanded=True)` 允许寻找
候选前最多 1.4 秒的篮筐飞行段，并容纳图像中的水平弯曲。第一轮已有射手判断应直接返回，
只用第二轮结果替换弃权；原预测及人工记录分别保留，后续视频使用冻结规则验证。

实验调用方可用 `with_release_contacts` 补充出手提示前后各 0.4 秒内、通过置信度与轨迹
距离筛选的真实球观测。持球阶段不必严格落在离手后的抛物线上；拟合轨迹及其观测保留原样，
外推位置只用于筛选，不能充当接触证据。人物帧可覆盖提示前后各两帧（5 fps 代理上各
0.4 秒），以避免停在举球前，或仅凭球离手后靠近防守人就选错人。
针对碰筐后才产生的较晚候选，可显式传入 `earlier_rim_seconds=2.6` 搜索更早的飞行段；
默认仍为 1.4 秒。这些实验规则不改变候选清单、进球判断或已保存的人工审核。

紧邻离手前一帧的较弱球检测（置信度 0.25–0.35），还必须接上两个方向一致的真实上升
球观测，才可补充为接触证据。离手前若某个人与球的接触明显强于其他人，优先使用同帧的
持球归属及后续分离证据，避免球已飞起后恰好靠近防守人的手。弱球证据的结果仍标为
`tentative`；多人重叠且持球归属不清楚时继续弃权。这些规则只重用已有局部人物框和球
观测，不增加人物模型调用，也不启用跨片段身份关联。
