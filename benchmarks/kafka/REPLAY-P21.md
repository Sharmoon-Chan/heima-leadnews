# P2.1 指定 DLT 消息人工重放

入口是 `replay-p21-dlt.ps1`，底层使用项目已有 kafka-clients 2.5.1。每次只读并重放指定的一个 DLT topic/partition/offset；`EventId` 必须与原消息的 `eventId` header 完全一致。只允许本卡的 `p21-20261108-*` 测试 topic，DLT 必须以 `.DLT` 结尾。

先编译 `P21ReplayCli.java` 到本轮 artifact 的 classes 目录，并将该目录与现有 search lib 加入 ClassPath。例如在外层项目目录执行：

```powershell
$artifact = 'D:/Code/Java/heima-leadnews/_optimization-artifacts/20261108-P2.1-MQ-r01'
$lib = 'D:/Code/Java/heima-leadnews/_optimization-artifacts/20261029-P0.1/lib-search/*'
javac -encoding UTF-8 -source 8 -target 8 -cp $lib -d "$artifact/classes" heima-leadnews/benchmarks/kafka/P21ReplayCli.java
$cp = "$artifact/classes;$lib"
```

以下参数须来自本卡已留存的 DLT 回执。先预览，检查实际事件、源 topic/partition/offset、原 key、原始 payload 字节、SHA256 和完整 headers；预览不会发送、提交 offset 或创建 journal：

```powershell
$selection = @{
  BootstrapServers = '192.168.200.130:9092'
  DltTopic = $selectedDltTopic
  Partition = $selectedDltPartition
  Offset = $selectedDltOffset
  EventId = $selectedEventId
  TargetTopic = $originalSourceTopic
  ClassPath = $cp
}
./heima-leadnews/benchmarks/kafka/replay-p21-dlt.ps1 @selection
```

确认目标必须等于原 DLT header 中的源 topic，重放分区使用原源分区；该分区必须存在。故障解除后，显式执行一次：

```powershell
./heima-leadnews/benchmarks/kafka/replay-p21-dlt.ps1 @selection `
  -Execute -ConfirmTarget $originalSourceTopic -ReplayId $newUniqueReplayId `
  -PayloadSha256 $payloadSha256FromPreview `
  -Journal "$artifact/evidence/replay-journal.jsonl" -RatePerSecond 1
```

执行必须传入预览中的 `payload_sha256`（Java 参数为 `--payload-sha256`），完整64位十六进制值；读取选定记录后再次计算并比较原始字节哈希，不符则在发送和 journal 写入前拒绝。预览可省略这个参数。

同卡所有执行必须使用同一个 journal。journal 文件锁将同 journal 的执行串行化，持锁期间通过同一个 FileChannel 读取和追加，兼容 Windows 强制文件锁。允许速率为 0.1–1 条/秒，按持久化的上次发送意图计算间隔。工具先落盘并强制 flush `SEND_INTENT`（包含原始字节、确认哈希、完整 headers、原 delivery attempt、坐标和本次重放序号），再调用发送；确认后记录 `BROKER_ACKNOWLEDGED` 的目标 topic/partition/offset。发送异常记录 `SEND_NOT_CONFIRMED`，不能据此断言 broker 未收到。进程崩溃可能只留下 intent；应先核对 broker，而不是自动重发。

发送使用 acks=all、enable.idempotence=true、retries=10、max.in.flight=5，send Future 等待最多15秒；delivery timeout为12秒，metadata max.block为10秒。完整保留原 key/value/header，增加 `p21_replay_id`、`p21_replay_count` 和 `p21_replay_dlt`。每次重复重放使用新 ReplayId；相同 ReplayId 会被拒绝。重放序号累计同一 DLT 坐标的发送意图数，不能当作已成功次数。

broker 回执仅证明发送被确认。还要在场景证据里核对消费成功、目标 ES 文档内容及重复重放后的结果。本工具不删除 DLT、不改 consumer group offset、不提供业务事件去重，也不能保证旧事件不会覆盖新内容。

离线护栏检查可将 `P21ReplayCliChecks.java` 与主类一起编译，然后运行 `P21ReplayCliChecks <全新检查journal路径>`。其17项检查验证身份/目标/元数据拒绝、执行哈希绑定、原始字节留存和持排他锁的同 channel 读写，不替代真实 broker 重放。
