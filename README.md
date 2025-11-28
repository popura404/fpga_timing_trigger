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

目标器件 XC7Z020-2CLG400I，100 MHz 尚待实际实现检查。板卡引脚、时钟源及硬件连接
尚未确认，当前不提供虚构的板级约束或上板结果。
