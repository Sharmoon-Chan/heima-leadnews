# TOOL-013：尾部等待的失败回执（使用前窄修）

对应交付：[TOOL-013 交接](../records/TOOL-013-交接.md)。只讲机制、时序与判据，不重复逐项检查表。

## 1. 缺陷形状

```
请求发出  ──►  Task 在途  ──►  连接被对端提前关闭（正文未收全）
                                   │
                                   ▼
                        Task.Status = Faulted
                                   │
        ┌──────────────────────────┴───────────────────────────┐
        │ 旧 Wait-P13c4CompletionPersist                        │
        │   while (未到截止) {                                  │
        │       Complete -> task.IsCompleted? 还没轮询到        │
        │       task.Wait(3)  ──► 抛 AggregateException ──► 跳出 │
        │   }                                                    │
        │   => Complete 从未执行 => 账本里 0 行                  │
        └───────────────────────────────────────────────────────┘
```

关键点：`Task.Wait` 在任务终态为 Faulted 时**抛出**而不是返回 `false`。所以「下一轮循环先看到 `IsCompleted`」这条兜底路径在真正故障时根本走不到。原故障原件 `20261104-P1.3c4-Bfix2-FAULT-REVIEW-r01` 的 3 试中 2 试就是这种 0 行。

## 2. 修后的等待

```
while (未到截止) {
    已完成? -> Complete（成功或失败都由它序列化）-> return true
    刷新 last_incomplete_ms
    try { task.Wait(3ms) }
    catch {
        wait_threw = true; wait_error = 消息
        Complete(...)  -> 非 null 就 return true     // 终态失败回执在这里落地
        否则原样 throw                                // 不是终态就不许吞
    }
}
```

三条边界：

- **只包 `task.Wait` 这一句**。基线门禁、`Ledger.Add`、`WriteLine`、`Flush` 的异常不经过这个 catch。
- **成功路径一字未改**：首次 `Complete` 命中即返回；3ms 切片、deadline、时间字段含义不变。
- **响应式等待的异常出口**（`Send-P13c4Responsive`）也只在抛之前多做一件小事：`Update-P13c4Tracked` 一次，把已经完成的 tracked 请求先落盘，再把原异常抛出去。

## 3. 时间字段与「失败」的表示

| 字段 | 失败回执里的含义 |
|---|---|
| `dispatched_ms` | 发出前 |
| `last_incomplete_ms` | 最后一次看到 Task 仍未完成 |
| `task_completed_observed_ms` / `ended_ms` | 第一次看到 Terminated（Faulted 也算终结） |
| `persisted_ms` | 写标（序列化前） |
| `flush_returned_ms` | Flush 返回；**不入行**，列在运行结果 |
| `http` / `error` / `failure` | `-1` / 客户端异常文本 / `true` |

**不写 `body` 与 `bytes`**：`ResponseContentRead` 在传输中断后不提供正文，任何字节数都是编的。这与「HTTP 500 保留正文」是有意的区别——500 是业务响应（有正文、有 sha256、没有 `failure` 标记），传输故障是另一类事件。

## 4. 判据（怎么算通过）

```
A 已 Faulted 再 Wait   ：不抛、返回 true、恰 1 行、字段齐全、无 body       （3 次）
B Wait 进行中变 Faulted：wait_threw=true、不抛、返回 true、恰 1 行          （3 次）
C 成功 / 500            ：正文与 sha256 可复算；重复 Wait+Complete 行数不变
D 仍 pending            ：deadline 处返回 false、0 行、事后也不补造
端点                     ：真实 abort early 3 / late 3（不是 HTTP 状态码）
原 34 项                 ：同一最终 helper 下 34/34
```

## 5. 边界

- 只覆盖「真实传输中断 → Task Faulted」；DNS 失败、连接被拒、取消、超时等其它终态组合未逐一验证，**不宣称全覆盖**。
- 端点进程与驱动是本卡的私有留存协作者，不是业务窗口；结果不并入 P1.3c-4 的 585 次采样或候选成本比较。
- 生产代码/配置/启动入口未动，本卡未跑 Maven、未调用业务 HTTP、未连 MySQL/Redis。

## 6. 负责人实测与口径（2026-11-04）

通过[负责人验收](../records/20261104-TOOL-013-负责人验收.md)。最终实际helper独立14/14，原34项独立34/34；TCP正文未收全时Faulted的6条终态失败回执都恰一次保存，body/bytes不可取得则不编造；200与500完整正文独立复算。返回true代表已处理并持久化该终态回执，不代表HTTP或业务成功。

只在Task.Wait处捕获，失败收尾仍用Complete，写入/Flush或门禁错误不吞。仍pending的截止返回false/0行保持；停止端点后Task可能Faulted，结果中的清理后状态不是截止时状态。本卡不调用数据库/业务，端点原件是私有留存协作者，不并c-4窗口或成本。TOOL-013在这条传输断连范围关闭，其余终态组合未据此全覆盖。
