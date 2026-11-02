---
name: ansys-solve-monitor
description: Use when the user starts or is about to start an ANSYS Workbench/Mechanical solve and wants progress reported in the chat instead of a separate window, or asks "求解到哪了 / 有没有卡住 / 跑完了吗 / 帮我盯着求解". Reads file.mntr + solve.out + ds.dat to report substep, time, displacement, plasticity, stall, and the final verdict, without touching the model or the solve.
---

# ANSYS 求解进度（对话内汇报）

用一条零依赖的 PowerShell 脚本读取求解现场，把进度和结论直接汇报在对话里。**只读**：不改模型、不点求解、不结束进程（除非用户明确要求）。

## 工具位置

- 脚本：`D:\主线任务\ansys-solve-monitor\dsh-watch.ps1`
- 配置：同目录 `config.txt`（`项目根目录=` 留空则自动扫描 `*_files`）
- 若脚本不存在，先 `Test-Path` 确认；不存在时按"手动取证"一节直接读文件。

## 一帧快照（最常用）

```powershell
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File 'D:\主线任务\ansys-solve-monitor\dsh-watch.ps1' -Snapshot
```

输出示例：

```
[求解中] 子步 87  物理时间 8.7 / 15 s  (58%)
  位移 412.6 mm（峰值 412.6）  塑性应变 本步 0.0031 / 峰值 0.0215  时间步 0.1
  已耗时 61.2 分钟  平均每子步 42.1 秒
  距上次更新 0.8 分钟
```

判读规则：

| 现象 | 含义 | 动作 |
|---|---|---|
| `求解中` + 距上次更新 < 5 分钟 | 正常推进 | 只报进度 |
| 距上次更新 > 15 分钟且子步没变 | 可能卡住（换页/分解慢） | 提高警惕，继续观察；不要立刻下结论 |
| 距上次更新 > 30 分钟且子步没变 | 判卡死 | 汇报给用户，**由用户决定**是否停止 |
| `未检测到 ANSYS 求解进程` + 结论 `RUN COMPLETED` | 已算完 | 给结果总结 |
| 结论含 `REASON FOR TERMINATION` | 求解失败 | 读 `solve.out` 末尾定位原因 |

先跑 `-Snapshot` 再说话；不要凭上一次的印象回答。

## 守候模式（长时间无人值守）

```powershell
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File 'D:\主线任务\ansys-solve-monitor\dsh-watch.ps1' -Wait -IntervalSec 60 -StallMinutes 30
```

- 每 60 秒往 `dsh_watch_<时间戳>.log` 追加一行；进程退出或判定卡死时打印总结。
- 用 **后台作业**（`run_in_background`）启动它，期间可以继续做别的事，任务结束时会收到通知。
- 卡死后行为由 `config.txt` 的 `卡死后动作` 决定，也可用 `-StallAction` 覆盖：
  - `提醒`（默认安全值）：只写日志，监控继续
  - `退出监控`：记一行后自己退出，求解不动
  - `停止求解`：**结束 MAPDL 进程**（先校验命令行含 `-b`，否则拒绝）

## 完成后的结果总结（用户要看的是结论）

按顺序取证，全部只读：

1. 结论：`Select-String -Path '<MECH>\solve.out' -Pattern 'RUN COMPLETED|REASON FOR TERMINATION|FINISHED SOLVE|ERROR MESSAGES'`
2. 末行数据：`<MECH>\file.mntr` 最后一条 `^\s*1\s+\d+\s+` 行（11 列：`LS Sub ? ? CumIter dt Time Wall MxDs MxPl MxRe`）
3. 规模与内存：`solve.out` 里 `Number of total nodes`、`Sum of memory allocated`、`Elapsed time`、`Total amount of I/O`
4. 接触参与：`For total <n> contact elements, there are <m> elements are in contact`
5. 云图（可选，绕开 Mechanical 界面）：见下

汇报模板：

```
求解完成：151/151 子步，t=15.000 s，耗时 1 h 45 min，0 error
  最大位移 622.94 mm，塑性应变峰值 0.1499（准则 0.15）
  桩土接触 7272 个接触单元中 5298 个参与（73%）
  结论：…
```

## 云图直出（Mechanical 没有"读取结果"时的替代方案）

```powershell
Remove-Item 'D:\awbtmp\mech' -Recurse -Force -ErrorAction SilentlyContinue
cmd /c mklink /J "D:\awbtmp\mech" "<项目>_files\dp0\SYS\MECH"
& 'E:\ANSYS R2\ANSYS Inc\v242\ansys\bin\winx64\ANSYS242.exe' -b -np 1 -dir 'D:\awbtmp' -i 'D:\awbtmp\pics.inp' -o 'D:\awbtmp\pics.out'
```

`pics.inp` 要点：`/POST1` → `FILE,'D:\awbtmp\mech\file','rst'` → `SET,LAST` → `/GRAPHICS,POWER` → `/VIEW,1,1,1,1` `/VUP,1,Z` `/AUTO,1` `/DSCALE,1,1` → `/SHOW,PNG,,0` → `PLNSOL` → `/SHOW,CLOSE`；输出 PNG 自动命名 `file000.png`…，用 `read_image` 查看。

## 硬约束

- **停止求解要有依据**：只有 `卡死后动作=停止求解`、或用户当场明确说"停"，才结束进程。结束前必须校验进程命令行含 `-b`（MAPDL 批量求解），否则只报告不动手。
- **不改模型、不重新提交求解**。监控只读。
- 卡死阈值默认 **30 分钟**：实测出现过单子步卡 37 分钟但最终跑完的情况（内存换页），阈值定太低会误杀。
- 判定"在算"而不是"卡住"的依据：ANSYS 进程 CPU 时间在涨 + `file.mntr` 有新行 + `file.stat` 的 `Solver iteration` 在变。
