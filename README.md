# 四通道同步时序与触发控制器

单时钟、四路注册输出，每路使能/延迟 D/脉宽 W，公共周期 P、有限重复 R。
默认 D/W/P 为 32 位，R 为 16 位。接受同步触发的边沿为 t0：第 k 次重复
在 `[t0+kP+D, t0+kP+D+W)` 为高（0≤k<R），t0+RP 后输出归零、done 高一拍。
D=0 可在 t0 后为高；D=0、W=P 的重复连续为高。

## 接口与命令

所有输入在 clk 上升沿采样，rst 为同步高有效复位。cfg_delay/cfg_width 为四个
TIME_W 位通道打包，通道 0 在最低位。TIME_W/REPEAT_W/COUNT_W 均须 ≥1，默认 32/16/32；
缩小参数用于边界回归。trigger 为一个时钟周期的同步脉冲；首版不含异步捕获或 CDC。

| command | 值 | 行为 |
| --- | --- | --- |
| NOP | 0 | 正常推进 |
| COMMIT | 1 | 仅 IDLE 采样整组 cfg_*，合法则 config_valid=1 |
| ARM | 2 | 仅 IDLE 且配置有效时进入 ARMED |
| CANCEL | 3 | 仅 ARMED 返回 IDLE，不产生 aborted |
| STOP | 4 | 任意状态返回 IDLE、输出清零；原为 RUN 则 aborted 高一拍 |

P、R 必须非零；每个启用通道须 W≥1 且 D+W≤P，端点用 TIME_W+1 位检查。
禁用通道的 D/W 不限制，全禁用仍运行完整周期。非法 IDLE 提交清除 config_valid，
必须重新合法提交才能武装；ARMED/RUN 提交被拒绝且活动配置不变。
未定义命令、错误状态下的命令、非法提交均产生一拍 command_error。

busy 只表示 RUN，armed 表示 ARMED。done、aborted、command_error 为独立单拍状态。
复位清除状态、活动配置、有效标志与诊断计数。STOP 优先于其他推进和触发，
包括正常结束边沿；STOP 同拍触发不计数。CANCEL 在 ARMED 屏蔽同拍触发。
IDLE 的 ARM 同拍 trigger 不会启动。其余被拒绝的命令不影响推进或 ARMED 接受触发。
RUN 的再次触发不重启，只累加 busy_trigger_count（COUNT_W 位自然回绕）；
完成同拍触发亦计数，输出不重启。完成、取消、停止保留配置，须重新 ARM。

## 仿真

依赖 Python 3 与 Icarus Verilog，无第三方 Python 包：

```sh
python3 scripts/run.py sim
# 只重跑受影响的位宽配置：
python3 scripts/run.py sim --widths default
python3 scripts/run.py sim --widths small
```

入口自动查找 PATH 或本机 E:/iverilog/bin，也可设置 IVERILOG、VVP。
所有生成文件位于忽略的 build/。sim/regression.py 从绝对事件区间产生独立期望，
SV 驱动器逐拍检查输出、运行/武装、完成/中止、配置状态、命令错误与忙时计数。
默认 32/16/32 回归检查 2,460 拍；4/3/3 回归检查 2,540 拍，其中完整执行
P=15、R=7 并使忙时触发计数回绕 13 次。每组含 5 个固定种子各 12 组配置。
默认位宽另有 3 个受限的内部 phase 注入探针，检查 2³¹ 与 2³²−1 附近的
比较/结束边沿；它们不代表连续运行了数十亿拍。默认不输出波形；失败显示
场景、种子/配置编号、边沿及实际/预期状态，向量保存在 build/sim/ 下供复现。
详细开发记录在工程旁 fpga_timing_trigger_worklog/，不进入 Git。

## 器件实现与资源对比

目标订货型号 XC7Z020-2CLG400I，Vivado 器件选择为 `xc7z020clg400-2`。
已使用 Vivado 2025.2 完成综合、布局、物理优化、布线和寄存器路径检查：

```sh
python3 scripts/run.py implement --mode both
python3 scripts/run.py sim --compare-fixed
# 复核既有 routed.dcp，不重复综合、布局或布线：
python3 scripts/run.py report --mode both
```

仅重建可配置核心可用 `implement --mode configurable`。入口查找 PATH 或本机
E:/AMDDesignTools/2025.2/Vivado/bin/vivado.bat，也可设置 VIVADO；本机已验证
WSL Python 调用 Windows Vivado/Icarus。原生 Windows 使用 `python` 替代 `python3`。

脚本在 build/vivado/ 中生成寄存器测试外壳：注册全部输入、采样全部输出，
BUFG 放在基准位置 BUFGCTRL_X0Y0。10 ns 时钟、0.1 ns 用户时钟不确定度，
对包括配置合法性检查在内的全部寄存器到寄存器路径做建立/保持检查。
该外壳仅用于基准测试，其输入/输出寄存器延迟不属于生产 RTL 的 t0 定义。
固定版由同一 RTL 的常量输入生成，四路 D=(0,2,4,6)、W=(2,2,2,2)、P=12、R=3。

| 版本 | 核心 LUT | 核心 FF | 寄存器 WNS | 寄存器 WHS |
| --- | ---: | ---: | ---: | ---: |
| 可配置 | 510 | 398 | +2.351 ns | +0.065 ns |
| 固定参数 | 187 | 91 | +4.660 ns | +0.095 ns |

表中资源不含外壳；含外壳分别为 753 / 138 FF，均额外使用 1 个 BUFG。
两版寄存器时序、时钟脉宽、约束覆盖和 DRC 错误检查通过；全部可布线网络完成布线。
相同 90 拍时间表在两版均通过，覆盖重复、忙时触发、停止及恢复。固定版修改参数
需重新综合；可配置版在 IDLE 提交参数即可，相对增加 323 LUT / 307 FF。
这些是指定基准的结果，不是整板资源或最高工作频率。

外壳端口采用 max/min=2.0/0.5 ns 的假设预算。两版当前的**整体时序状态为 FAIL**；
`implement` 和 `report` 都返回非零，`--mode both` 仍检查完两版后汇总失败。
这不阻止读取已生成的报告或运行独立仿真。metrics.txt 分别记录
register_benchmark_status 与 full_design_timing_status，不能只看局部 PASS。

2026-10-26 重开原布线检查点，逐类核查全部端点，保持检查结果如下：

| 路径 | 可配置版：失败/端点数、最差余量 | 固定版：失败/端点数、最差余量 |
| --- | --- | --- |
| 外壳输入 → 外壳输入寄存器 | 313/313，−1.511 ns | 5/5，−1.484 ns |
| 寄存器 → 寄存器（含核心配置和运行路径） | 0/1220，+0.065 ns | 0/297，+0.095 ns |
| 外壳输出寄存器 → 外壳输出 | 0/42，+1.858 ns | 0/42，+1.863 ns |

全部负值止于外壳输入寄存器，没有核心直达或未分类的失败路径。可配置版最差路径为
`cfg_delay[24] → cfg_delay_q_reg[24]/D`，不经过核心组合逻辑。数据到达时间为
0.500+0.748=1.248 ns，保持要求约为 2.279+0.135+0.344=2.758 ns。
其中数据网络状态为 HIERPORT、ROUTE 为空；时钟端口到 BUFG 的一段亦为估算，
BUFG 后的 core_clk 则已实际布线。显示值取整后的差值与原始 slack 存在微小差异。

因此约束并未遗漏，问题是当前假设预算与缺少真实连接位置的 OOC 边界模型无法闭合，
现有证据没有显示核心 RTL 保持违例。[AMD UG905](https://docs.amd.com/r/en-US/ug905-vivado-hierarchical-design/Context-Constraints)
说明 OOC 接口网络默认不布线，需要物理上下文。并行 cfg_* 是片内寄存器接口，
不应把全部位直接分配成板外 GPIO。需在实际寄存器/VIO 等顶层集成后重新检查，
真正板外接口还须有器件时序、板卡引脚、时钟及走线资料。
本次修复了报告分类和失败退出状态，未改 RTL、时钟、输入/输出延迟、不确定度或异常路径，
未添加人工延迟来掩盖失败；缺少实际集成上下文时不声称外部保持问题已修好。

每版的 metrics.txt、timing_boundary.rpt、timing_input_paths.rpt、timing_output_paths.rpt、
timing_register_paths.rpt、timing_summary.rpt、timing_constraints.xdc（实际约束快照）、
utilization_core.rpt、route_status.rpt、check_timing.rpt、drc.rpt 和 routed.dcp
均在 build/vivado/<版本>/，可删除 build/ 后从源码重建。RTL、测试、工具入口
分别位于 rtl/、sim/、scripts/；工程仅保留这一套 RTL 和自检环境。
`report` 使用检查点中的约束；指标中的 build_default_* 仅说明构建入口默认值，
实际器件、周期和 BUFG 位置取自当前设计，完整约束以快照为准。

## 当前缺项

2026-10-26 已连接本地硬件服务器，检测到 0 个下载目标。缺少具体板卡型号、
时钟来源、GPIO 引脚与电平资料；尚未做板级适配、PS7/调试通道集成、比特流生成、
下载、ILA 三组配置观察或外部仪器测量。OOC 的 ZPS7-1 警告保留在报告中。
拿到真实板卡条件后，应验证同时输出、错开输出、有限重复三组，并检查停止延迟。
100 MHz 基准下的数字时间单位为 10 ns；板上时钟、物理抖动和通道偏斜尚无实测证据。
