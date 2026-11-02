# ANSYS Solve Monitor · ANSYS 求解监控器

一个零依赖的 ANSYS Mechanical 求解进度监控小工具。
A dependency-free live monitor for ANSYS Mechanical solves.

**用 Windows 自带 PowerShell 写的，不用装 Python、不用装 Ansys 的 Python 包、不改任何 ANSYS 设置。**
Built on the PowerShell that ships with Windows — no Python, no PyAnsys, no ANSYS configuration changes.

```
  ================  ANSYS 求解监控  ================
  时间 21:07:12   轮询 5s   卡死判定 12 分钟
  求解进程 pid=5768   已运行 1h10m   CPU 4,210s   内存 5,120 MB
  结果目录 D:\project\model_files\dp0\SYS\MECH
  求解器   Sparse (unsymmetric)
  进度 [######################..............]  51.3%   t = 7.695 / 15.000 s

  子步 96      累计迭代 101      位移    318.42 mm   塑性  1.492E-001   残差      36.65 N
  求解墙钟    4,210 s (1h10m)   本步用时 0m39s
  预计剩余 1h12m   预计完成 22:19
------------------------------------------------------------------
  最近子步走势:
      子步     时刻t(s)      位移(mm)       塑性应变     累计墙钟
        91     7.245      301.15   1.489E-001       3,975
        92     7.340      313.88   1.490E-001       4,014
        ...
```

---

## 为什么需要它 / Why

ANSYS 的进度条长时间停在 `1%` 是很常见的现象——它在建矩阵、组装方程、做稀疏分解，
这些阶段不产生子步，界面上完全看不出是在算还是已经卡死。

This tool answers three questions at a glance:

| 问题 | 界面对应 |
|---|---|
| 到底在算还是卡了？ | 进度条 / `t` 值 / `距上个新子步` 分钟数 |
| 收敛正常吗？ | 位移、塑性应变、残差的逐子步走势 |
| 还要多久？ | `预计剩余` / `预计完成` |

---

## 快速开始 / Quick start

### 方式 A：双击（推荐）

1. 在 Mechanical 里点「求解」；
2. 双击 `启动监控.bat`；
3. 挂着就行。求解结束会响两声并打印总结。

先开监控也可以——它会显示「等待求解开始……」，你点求解后自动接上。

### 方式 B：把工程文件拖到 bat 上

把 `.wbpj` 文件直接拖到 `启动监控.bat` 图标上，它会用该工程所在目录作为根目录。

### 方式 C：命令行

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\monitor.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\monitor.ps1 -Root "D:\myproject"
powershell -NoProfile -ExecutionPolicy Bypass -File .\monitor.ps1 -Once        # 打印一帧自检
powershell -NoProfile -ExecutionPolicy Bypass -File .\monitor.ps1 -Diagnose    # 看目录探测结果
```

**按 `Q` 退出监控 —— 只关窗口，不会停止求解。**

---

## 在其他电脑上使用 / Portability

拷贝整个文件夹到任意位置即可，**不需要改代码、不需要装任何东西**。

工程目录的定位顺序：

1. 命令行 `-Root`（或拖入的 `.wbpj` 所在目录）
2. `config.txt` 里的 `项目根目录`
3. 工具自身所在目录及其上两级（把工具放进工程目录时就零配置）
4. 全盘扫描（`自动扫描=on` 时；找 `*_files\dp0\*\MECH` 和 `_ProjectScratch`）

扫描结果会缓存 60 秒，避免反复全盘遍历。

### 依赖 / Requirements

| 项 | 要求 |
|---|---|
| 操作系统 | Windows 7 / 10 / 11 / Server |
| PowerShell | 5.0+（Win10 起自带 5.1） |
| ANSYS | 2020 R1 及以上（实际只读文本文件，版本无关） |
| 其他 | 无。不需要 Python、不需要管理员权限、不需要联网 |

脚本已针对中文路径做了处理，工程路径含中文/空格都能正常识别。

---

## 它读什么、不读什么 / What it touches

**完全只读**，不写、不删、不改任何 ANSYS 文件：

| 文件 | 用途 |
|---|---|
| `file.mntr` | 子步、时刻、墙钟、最大位移、最大塑性应变、残差 |
| `file.stat` | 稀疏/PCG 求解器内迭代次数与残差比 |
| `ds_file.stat` | 当前迭代计数 |
| `solve.out` | 求解器类型、结束状态（`RUN COMPLETED`） |
| `ds.dat` | `dime,` 结束时间，用于算进度百分比 |

它不会启动、停止或影响求解进程。

---

## 配置 / Configuration

改 `config.txt`，保存后重新启动监控：

```ini
项目根目录=                 # 留空=自动扫描；多个用 ; 分隔
卡死判定分钟=12             # 超过这么多分钟没有新子步就判定卡死
卡死后动作=提醒             # 提醒 / 退出监控 / 停止求解
刷新秒数=5
提示音=on
自动扫描=on
```

### `卡死后动作` 三种模式

| 取值 | 行为 | 适用场景 |
|---|---|---|
| **提醒**（默认） | 红字 + 响铃，监控继续运行，每轮都提醒 | 想自己盯着、自己决定什么时候停 |
| **退出监控** | 红字 + 响铃后监控**自己退出**，求解不受影响 | 挂着不管，发现报警回来自己处理 |
| **停止求解** | 红字 + 响铃后**直接结束 ANSYS 求解进程** | 无人值守，宁可放弃这一轮也不让它白烧一夜 |

`停止求解` 带安全检查：只有当目标进程命令行确实是 `ANSYS.EXE ... -b ...`（MAPDL 批量求解）时才会结束它，
否则只报警不动作。注意被停掉的那一轮**结果不完整**，需要重新求解。

---

## 卡住了怎么办 / When it warns

出现红色报警：

```
  !! 已经 12 分钟没有新子步，可能卡住或已发散
     按配置：正在结束求解进程（卡死后动作=停止求解）
```

不同 `卡死后动作` 下的处理方式：

1. **提醒**（默认）：先别急，偶尔一次磁盘/换页等待会卡两三分钟；确实超过阈值，再去 Mechanical 里
   右键「求解」→「停止求解」，然后看 `file.err`（界面下方会显示目录），常见原因就在里面。
2. **退出监控**：监控自己退出，求解还在跑，你需要回去手动停。
3. **停止求解**：监控直接结束 MAPDL 进程，退出码 3。此轮结果不完整，需要重算。

> 判断是否真的卡死，除了「没有新子步」，还可以看界面上的 `求解器 …` 那一行：
> 内迭代次数一直在涨、残差比在降，说明它还在算（只是慢），不算卡死。

---

## 退出码 / Exit codes

| 码 | 含义 |
|---|---|
| 0 | 正常运行或被 `Q` 正常退出 |
| 非 0 | 脚本异常，看控制台输出 |

---

## 常见问题 / FAQ

**双击 bat 一闪而过？**
本工具用 `-ExecutionPolicy Bypass` 启动子进程规避策略限制，正常不会出现。
若仍有问题，在该目录 Shift+右键 →「在此处打开 PowerShell 窗口」，运行：
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\monitor.ps1
```

**一直显示「等待求解开始」但明明在算？**
配置里的 `项目根目录` 不对，或者工具不在工程目录里。用 `-Diagnose` 看探测结果：
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\monitor.ps1 -Diagnose
```

**进度一直是 0%？**
求解刚开始要建矩阵/组装方程，这段时间还没有子步数据，属正常。
看「求解器」那行有没有迭代数在涨即可。

**能同时监控两个求解吗？**
不能，只跟"最新活跃"的那一个。

**会拖慢求解吗？**
不会。每 5 秒读几个几 KB 的文本文件，开销可以忽略。

---

## 仓库结构 / Layout

```
ansys-solve-monitor/
├─ 启动监控.bat      # 双击这个
├─ monitor.ps1       # 主程序
├─ config.txt        # 配置
├─ 使用说明.md       # 详细说明（中文）
└─ README.md         # 本文件
```

每次运行会在同目录生成 `monitor_日期_时间.log`，跑完可留档对照（已在 `.gitignore` 中忽略）。

---

## License

MIT

---

## 反馈 / Issues

https://github.com/1525627511/ansys-solve-monitor/issues
## 集成到 DeepSeek Harness（对话内汇报）

除了独立窗口，本工具还可以把求解进度**直接汇报在 AI 对话里**。核心脚本是 `dsh-watch.ps1`（零依赖，只读）。

### 1. 装成 DSH skill（一次配置，永久生效）

把 `SKILL.md` 复制到 DSH 的用户技能目录：

```powershell
$dst = "$env:USERPROFILE\.dsh\skills\ansys-solve-monitor"
New-Item -ItemType Directory -Path $dst -Force | Out-Null
Copy-Item 'SKILL.md' $dst -Force
```

放好后 DSH 会**热加载**，技能目录里立刻出现 `ansys-solve-monitor`。之后你直接说"帮我盯着求解"，AI 就知道该读哪些文件、怎么判卡死、怎么总结结果。

### 2. 手动调用（不装 skill 也能用）

```powershell
# 一帧快照
powershell -NoProfile -ExecutionPolicy Bypass -File dsh-watch.ps1 -Snapshot

# 守候到结束（每 60 秒记一行日志）
powershell -NoProfile -ExecutionPolicy Bypass -File dsh-watch.ps1 -Wait -IntervalSec 60 -StallMinutes 30
```

快照输出：

```
[求解中] 子步 87  物理时间 8.7 / 15 s  (58%)
  位移 412.6 mm（峰值 412.6）  塑性应变 本步 0.0031 / 峰值 0.0215  时间步 0.1
  已耗时 61.2 分钟  平均每子步 42.1 秒
  距上次更新 0.8 分钟
```

### 3. `-Wait` 与窗口版的分工

| | `monitor.ps1`（窗口） | `dsh-watch.ps1 -Wait`（对话） |
|---|---|---|
| 显示 | 全屏实时刷新 | 写日志，AI 读日志汇报 |
| 卡死 | 可红字响铃、按配置停止求解 | 只判卡死并退出，**不动进程** |
| 适合 | 人盯着屏幕 | 挂机，让 AI 全程跟踪并在结束时给结论 |

### 4. 安全边界

`dsh-watch.ps1` 默认只报警不动手；把 `config.txt` 的 `卡死后动作` 设成 `停止求解` 后它才会结束 MAPDL 进程（先校验命令行含 `-b`，否则拒绝）。它从不改模型、不重新提交求解。卡死阈值默认 30 分钟——实测出现过单子步卡 37 分钟但最终跑完（内存换页）的情况，阈值太低会误杀两小时的计算。