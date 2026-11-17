# TOOL-013 交接：尾部等待失败回执窄修

派卡：2026-11-04（[原卡](../02i-TOOL-013-尾部等待失败回执窄修任务卡.md)）。前置：[P1.3c-4 最终负责人验收](20261104-P1.3c4-最终负责人验收.md)（整卡通过、LIFECYCLE-009 不重开）、[台账 TOOL-013](问题台账.md)。

本卡只修一条遗留工具路径：`Wait-P13c4CompletionPersist` 在 Task 已进入终态故障时，`Task.Wait` 先抛异常，导致 `Complete-P13c4Get` 从未执行、该请求**没有任何失败回执**。**生产源码、配置、启动入口、500ms/256/单线程/事务/公开响应全部未动；未跑 Maven、未调用业务 HTTP、未连 MySQL/Redis。**

## 1. 现场核对（先冻结，再改）

运行根 `_optimization-artifacts/20261104-TOOL013-fix-run-r01/`（新增父入口 `benchmarks/env/prepare-tool013-run.ps1`，接公共 `RunDirGuard`，`stage=TOOL-013-prepare`，封存集 84、可写目录 6 个）。

改前冻结在 `inputs/inputs-before.json`：helper `1e7763ad…`、`RunDirGuard.ps1` `e25da148…`、原 34 项驱动 `d36fb43e…`、窗口脚本 `d8f1da52…`、HEAD `5a143ad5…`、tracked 改动 19 项、生产四文件 hash。改后 `inputs/inputs-after.json` 逐项对比：**除 helper 与新驱动外全部一致**，HEAD 与 tracked 状态逐字节一致（`git.status_entries_unchanged=True`）。

原故障原件保持只读并再核对：`20261104-P1.3c4-Bfix2-FAULT-REVIEW-r01` 清单 `40ca16f3…`（19 项）、`20261104-TOOL013-DISPATCH-r01` 清单 `1a905153…`（19 项）。旧 424/481/202/217 清单 hash 与上一轮完全相同（见 `summary.json.previous_roots_untouched`）。

## 2. 工具 diff（唯一改动文件）

`benchmarks/lib/P13c4Evidence.ps1`：`1e7763ad…` → **`db3536a7…`**；补丁原件 `probe/tool-diff.patch`（sha256 `6b5d30af…`）。三处、共 20 行新增 / 2 行改写：

| 位置 | 改动 | 为什么 |
|---|---|---|
| `Start-P13c4AsyncGet` | 新增内存字段 `wait_threw` / `wait_error` | 让驱动能证明「Wait 真的抛过」，而不是靠调用方猜；**不入账本行** |
| `Send-P13c4Responsive` | 分片循环里的 `task.Wait` 包一层 catch：先 `Update-P13c4Tracked` 收尾已完成 tracked，再原样 `throw` | 响应式等待的异常出口原本会跳过“已完成 tracked 的收尾”，与卡里第 4 条要求一致地做最小补充 |
| `Wait-P13c4CompletionPersist` | 只包 `task.Wait($SliceMs)`；捕获后标记 `wait_threw`，仍调 `Complete-P13c4Get` 落回执；**若 Complete 仍返回 null 则原样重抛** | 终态故障不再被丢成 0 行；不是终态时不吞异常 |

未改：3ms 切片、deadline 行为、时间字段含义（`dispatched_ms`/`last_incomplete_ms`/`task_completed_observed_ms`/`ended_ms`/`persisted_ms`/`flush_returned_ms`）、成功路径返回值、writer/reader/唯一 ID 机制。**捕获只包 `task.Wait`**：门禁、`Ledger.Add`、`WriteLine`、`Flush` 的失败照旧抛出。

## 3. 真实 TCP 提前断连的有限验证

驱动 `benchmarks/verify/tests/run-tool013-fault-offline.ps1`（新文件，`276878935f…`），调用的是**最终 helper**；私有端点 `127.0.0.1:19739` 运行在**独立进程**（`endpoint.ps1` 由驱动写一次），先写 1 字节再 `Response.Abort()` 关掉真实 TCP 连接，正文永远不满足 `Content-Length`。端点事件原件 `runs/TOOL013-FAULT-r02/endpoint-events.jsonl`（early 3 / late 3 次 abort）。

`TOOL013-FAULT-r02` **14/14 通过**：

| 模式 | 实测 |
|---|---|
| A 调用前已 Faulted（3 次） | 3/3 `task_status_before_wait=Faulted`；helper 未抛、返回 `true`；每请求**恰 1 行**，`request_id/method/path/started_ms/ended_ms/persisted_ms/last_incomplete_ms` 齐全；`http=-1`、`failure=true`、`error` 非空（“将内容复制到流中时出错…”）；**无 body/bytes 字段**（未补造正文） |
| B 等待中变 Faulted（3 次） | 3/3 进入 Wait 时任务仍 pending；`wait_threw=True`（证明是 Wait 真的抛）；helper 未抛、返回 `true`；每请求恰 1 行失败回执 |
| C 成功与 HTTP 500 | 成功 200 / 52B / sha256 可复算 / views=777；500 / 51B / 正文保留 / sha 可复算 / **不带 `failure` 标记**（业务响应不是传输故障）；重复 `Wait`+`Complete` 前后行数 8→8 |
| D 仍 pending | 在 1200ms 截止处返回 `false`（实测 1214ms），`0` 行，任务未 Faulted；端点被停后该请求仍是 `0` 行，**没有补造终态回执** |
| 账本整体 | 8 行 = A3+B3+成功+500，`seq` 1..8、8/8 唯一、不可解析 0；写流仍打开时可读 8 行，单次 Close 后 hash `f097e6d5…` |

**失败原件按卡保留**：`TOOL013-FAULT-r01` 12 项全过但自身在 Close 之前对仍打开的账本做 `Get-FileHash`（sharing violation），脚本中止、`run-error` 与全部原件保留；r02 才把 hash 移到 Close 之后并补上「写流打开时可读」检查。

## 4. 原 34 项回归

同一最终 helper 下在新 run_id 重跑既有驱动（驱动文件 hash 与改前一致 `d36fb43e…`，未改测试）：`TOOL013-LEDGER34-r01` **34/34** —— 阻塞 sample 期间留存推进（早 1252ms）、独立观察者首见晚 33ms、中断后已完成慢读仍在盘、`every_request_on_disk` 13=14−1、`one_record_per_request_in_order` 13/13。

## 5. 证据与收尾

- 本根 `artifacts-sha256.tsv` **36 项**，独立复算 36/36（0 不符 / 0 缺失 / 0 多余），清单 **`7a12d763…`**；`summary.json` **`490cd2fd…**（含工具前后 hash、补丁 hash、两轮 checks counts、逐项输入冻结、旧根清单核对）。
- 逐请求原件：`runs/TOOL013-FAULT-r02/requests.jsonl`（8 行，含失败 `error` 与成功正文）、`fault-offline-result.json`、`fault-offline-checks.tsv`、`endpoint-events.jsonl`、`endpoint.ps1`、`endpoint.*.txt`；`runs/TOOL013-LEDGER34-r01/` 为原 34 项全套。
- 进程清理：端点子进程由驱动停止（19100–19800 端口监听 0）、`java` 进程 0、51819 无监听；MySQL/Redis 未连，基础服务与他人进程未动。
- 未提交；HEAD 仍 `5a143ad5…`；tracked 改动仍 19 项。**未进入 P2**。

## 6. 边界（不宣称）

- 只覆盖「Task 因真实传输中断进入 Faulted 后，等待路径仍要落回执」这一条；**不宣称覆盖全部传输异常**（DNS/连接被拒/取消/超时后的其它终态组合未逐一测）。
- 失败回执的 `error` 是客户端异常文本，正文在 `ResponseContentRead` 故障后**不可取得**，故不写 `body`/`bytes`，也不反推字节数。
- 端点与驱动都是本卡的私有留存协作者，**不是业务窗口**，其结果不并入 P1.3c-4 的 585 次采样或任何候选成本比较。
- 台账 TOOL-013 记 **已执行待验收**，由负责人复验后关闭。

交回 **TOOL-013 验收**。未提交、未进入 P2、不自行派下一张卡。

## 7. 负责人复验（2026-11-04）：通过

见[负责人验收](20261104-TOOL-013-负责人验收.md)。独立新私有根真实断连14/14、原34项34/34；A已Faulted与B等待中Faulted各3次，失败回执恰一次，成功/500正文与重复调用保持，截止pending不补造。新36/36及旧217/202/481/424等清单匹配；19生产源/5support与tracked patch不变，端点清理，无业务/数据库/Maven调用。

计数勘误：19是git status总条目，14个tracked修改文件+5个未跟踪条目，不是19个tracked文件。D的Task状态在清理后可为Faulted，截止调用时仍pending，不混为一时点。TOOL-013按本卡真实传输断连范围关闭；P1.3c-4与LIFECYCLE-009保持，下一卡另派、不提交、不进入P2。
