# 同步时序与触发控制器

开发第 1 轮：单通道、一次周期的注册脉冲。同步高有效复位；输入参数须合法。
接受 `start` 的边沿为 t0，输出在 t0+D 到 t0+D+W−1 后为高，
t0+P 后归零、busy 下降、done 高一拍。运行中 start 不重启。

使用 Python 3 和 Icarus Verilog：

```sh
python3 scripts/run.py sim
```

入口自动查找 PATH 或本机 E:/iverilog/bin，也可设置 IVERILOG、VVP。
生成文件统一放在忽略的 build/；sim/ 中的独立绝对时间表逐拍检查输出。
四通道配置控制及指定器件实现将在后续开发轮次加入。
