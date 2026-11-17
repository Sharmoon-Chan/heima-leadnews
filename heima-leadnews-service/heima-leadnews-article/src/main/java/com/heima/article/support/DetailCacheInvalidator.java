package com.heima.article.support;

import com.heima.common.redis.CacheService;
import lombok.extern.slf4j.Slf4j;
import org.springframework.beans.factory.DisposableBean;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.data.redis.RedisConnectionFailureException;
import org.springframework.stereotype.Component;
import org.springframework.transaction.support.TransactionSynchronization;
import org.springframework.transaction.support.TransactionSynchronizationManager;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ScheduledFuture;
import java.util.concurrent.ScheduledThreadPoolExecutor;
import java.util.concurrent.ThreadFactory;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicLong;

/**
 * 写路径的详情缓存失效器。
 *
 * <p>P1.3a 解决的问题（CACHE-003）：原来 {@code saveArticle} 在事务内立刻删缓存、并在 +500ms 再删一次，两次都发生在
 * COMMIT 之前。现在：有实际事务时只登记「成功提交之后」的动作（{@code afterCommit}），回滚不执行；无事务时立即执行；
 * 删除失败只记录，不改变已经提交的事实。</p>
 *
 * <p>P1.3c-1 补充的是「延迟任务的生命周期与完成计数」，语义不变：</p>
 * <ul>
 *   <li>每次第二删是一个有进程内唯一 {@code task_id} 的任务；只有在 {@code schedule} 成功返回后才计
 *       {@code accepted}，拒绝单列并带原因；</li>
 *   <li>状态只沿 {@code QUEUED → RUNNING → SUCCEEDED|FAILED|CANCELLED} 单向前进，终态只写一次；
 *       「开始执行」不等于「删除成功」，成功只在 {@code delete} 真正返回之后记录；</li>
 *   <li>活跃任务表只保留排队/运行中的任务，进入终态即从表中移除，累计计数不会让已结束的任务留在内存里；</li>
 *   <li>Bean 销毁时用真实的 Spring 生命周期钩子关闭本组件自己创建的调度器：先拒绝新提交，再有界等待，
 *       到期后取消尚未执行的任务并计取消，最后记录关闭回执。</li>
 * </ul>
 *
 * <p>500ms 与单工作线程保持原值，本卡不调参。队列上限、窗口/候选参数比较、多进程与崩溃补偿都不在本卡。</p>
 */
@Component
@Slf4j
public class DetailCacheInvalidator implements DisposableBean {

    /** 与详情缓存使用同一个 key 前缀（这里只做失效，不读写缓存内容） */
    public static final String ARTICLE_DETAIL_KEY = "article:detail:";

    /** 延迟二次删除的等待窗口（毫秒），沿用现有候选值，本卡不调参 */
    static final long SECOND_DELETE_DELAY_MILLIS = 500L;

    /** 关闭时的有界等待默认值（毫秒）；可由 {@code p13c.evict.close-wait.ms} 覆盖，是工程配置而非压测选参 */
    static final long DEFAULT_CLOSE_WAIT_MILLIS = 2000L;

    /**
     * 第二删活跃任务上限的工程默认值（{@code max_active = queued + running}）。
     * 由 {@code p13c.evict.max-active} 覆盖；这是工程约束，不是压测选出的最优参数。
     */
    static final int DEFAULT_MAX_ACTIVE = 256;

    /** 第二删任务的状态。终态只允许写一次 */
    public enum TaskState { QUEUED, RUNNING, SUCCEEDED, FAILED, CANCELLED }

    /** 一个第二删任务；进入终态后从活跃表移除，对象随后不再被引用 */
    static final class SecondDeleteTask {
        final String taskId;
        final Long articleId;
        final String phase;
        final String cacheKey;
        final long acceptedAtMs;
        volatile TaskState state = TaskState.QUEUED;
        volatile long startedAtMs = -1L;
        volatile long endedAtMs = -1L;
        volatile String outcome = "";
        volatile ScheduledFuture<?> future;

        SecondDeleteTask(String taskId, Long articleId, String phase, String cacheKey, long acceptedAtMs) {
            this.taskId = taskId;
            this.articleId = articleId;
            this.phase = phase;
            this.cacheKey = cacheKey;
            this.acceptedAtMs = acceptedAtMs;
        }
    }

    private final CacheService cacheService;
    private final DetailProbe probe;
    private final long closeWaitMillis;

    /** 第二删活跃任务上限；{@code queued + running} 不得超过它 */
    private final int maxActive;

    private final ScheduledThreadPoolExecutor secondDeleteScheduler;
    private final String taskIdPrefix;

    /**
     * 进程范围的任务序列：同一个 JVM 里可能有多个 Context / 多个失效器实例，
     * 只有静态序列 + pid 才能保证 task_id 不撞车（不能用“时间窗不会重叠”当假设）。
     */
    private static final AtomicLong GLOBAL_TASK_SEQ = new AtomicLong();

    /** 活跃任务峰值，只在 {@code stateLock} 内更新 */
    private int activePeak;


    /** 接受/发布、开始执行、取消与终态共用的状态锁；持有时间只够做内存状态和一行事件 */
    private final Object stateLock = new Object();
    private final Map<String, SecondDeleteTask> activeTasks = new ConcurrentHashMap<>();

    // ---- 生命周期（关闭）状态
    private final AtomicBoolean closing = new AtomicBoolean(false);
    private volatile boolean closeFinished;
    private volatile boolean closeTerminated;
    private volatile long closeWaitedMillis = -1L;
    private volatile int closeQueuedAtStart = -1;
    private volatile int closeRunningAtStart = -1;
    private volatile int closeCancelledCount = -1;

    // ---- P1.3c-1 提交/状态计数（累计，单位：次）
    private final AtomicLong submitAttempts = new AtomicLong();
    private final AtomicLong accepted = new AtomicLong();
    private final AtomicLong rejectedClosed = new AtomicLong();
    private final AtomicLong rejectedScheduler = new AtomicLong();
    private final AtomicLong started = new AtomicLong();
    private final AtomicLong succeeded = new AtomicLong();
    private final AtomicLong failedSecond = new AtomicLong();
    private final AtomicLong cancelled = new AtomicLong();
    /** 只因活跃上限被拒的第二删任务数（与关闭拒绝、执行器拒绝分开） */
    private final AtomicLong rejectedBacklog = new AtomicLong();

    // ---- 原有累计计数（保留兼容；second_delete_scheduled 现在只统计「成功接受」）
    private final AtomicLong deleteAttempts = new AtomicLong();
    private final AtomicLong deleteFailures = new AtomicLong();
    private final AtomicLong afterCommitRuns = new AtomicLong();
    private final AtomicLong noTransactionRuns = new AtomicLong();
    private final AtomicLong rollbackSkips = new AtomicLong();

    /**
     * @param closeWaitMillis 关闭时的有界等待（毫秒）。应用内由 {@code p13c.evict.close-wait.ms} 提供，
     *                        缺省 {@value #DEFAULT_CLOSE_WAIT_MILLIS}；它是工程配置，不是本卡选出的参数。
     * @param maxActive       第二删活跃任务上限（{@code queued + running}）。应用内由
     *                        {@code p13c.evict.max-active} 提供，缺省 {@value #DEFAULT_MAX_ACTIVE}；
     *                        必须是正整数，否则构造即拒绝（明确报错，不静默回退）。
     */
    public DetailCacheInvalidator(CacheService cacheService, DetailProbe probe,
                                  @Value("${p13c.evict.close-wait.ms:2000}") long closeWaitMillis,
                                  @Value("${p13c.evict.max-active:256}") int maxActive) {
        if (maxActive < 1) {
            throw new IllegalArgumentException(
                    "p13c.evict.max-active must be a positive integer, got " + maxActive
                            + " (it bounds queued + running second-delete tasks)");
        }
        this.maxActive = maxActive;
        this.cacheService = cacheService;
        this.probe = probe;
        long effective = probe != null ? probe.closeWaitMillis(closeWaitMillis) : closeWaitMillis;
        this.closeWaitMillis = Math.max(0L, effective);
        this.taskIdPrefix = "t" + (probe != null ? probe.getPid() : "0") + "-";
        ThreadFactory factory = r -> {
            Thread t = new Thread(r, "p13a-cache-evict");
            t.setDaemon(true);
            return t;
        };
        ScheduledThreadPoolExecutor executor = new ScheduledThreadPoolExecutor(1, factory);
        //关闭后不再执行已排队的延迟任务：否则「已经 close 了却还在删」无法对账。
        executor.setExecuteExistingDelayedTasksAfterShutdownPolicy(false);
        executor.setContinueExistingPeriodicTasksAfterShutdownPolicy(false);
        executor.setRemoveOnCancelPolicy(true);
        this.secondDeleteScheduler = executor;
    }

    /**
     * 写路径调用入口：有事务就登记「提交后失效」，没有事务就立即失效。
     *
     * @param articleId 文章 ID（为空直接返回，不做任何事）
     * @param reason    调用来源，仅用于事件留痕（例如 {@code saveArticle:update}）
     */
    public void invalidateAfterWrite(Long articleId, String reason) {
        if (articleId == null) {
            return;
        }
        boolean inTransaction = TransactionSynchronizationManager.isSynchronizationActive()
                && TransactionSynchronizationManager.isActualTransactionActive();
        probe.event("cache.evict.register", 0L, articleId,
                "reason=" + reason + " inTransaction=" + inTransaction
                        + " txActive=" + TransactionSynchronizationManager.isActualTransactionActive()
                        + " syncActive=" + TransactionSynchronizationManager.isSynchronizationActive());
        if (!inTransaction) {
            //无事务分支：立即执行，并照现有策略安排第二次删除
            noTransactionRuns.incrementAndGet();
            probe.event("cache.evict.no_transaction_immediate", 0L, articleId, "reason=" + reason);
            performInvalidate(articleId, reason + ":noTransaction");
            return;
        }
        TransactionSynchronizationManager.registerSynchronization(new TransactionSynchronization() {
            @Override
            public void afterCommit() {
                //注意：afterCommit 期间同步器仍是 active 的，这里必须直接执行删除，
                //不能再走 invalidateAfterWrite（否则会把自己再登记一次 afterCommit）。
                afterCommitRuns.incrementAndGet();
                probe.event("tx.after_commit", 0L, articleId,
                        "reason=" + reason + " txActive=" + TransactionSynchronizationManager.isActualTransactionActive());
                performInvalidate(articleId, reason + ":afterCommit");
            }

            @Override
            public void afterCompletion(int status) {
                if (status != TransactionSynchronization.STATUS_COMMITTED) {
                    rollbackSkips.incrementAndGet();
                    probe.event("tx.rollback_skip_evict", 0L, articleId,
                            "reason=" + reason + " status=" + statusName(status));
                }
            }
        });
    }

    /**
     * 真正执行删除：立即删一次 + 按现有 500ms 策略提交一个第二删任务。
     * 失败只记录与计数，不抛出，不影响已经提交的写入结果。
     */
    void performInvalidate(Long articleId, String phase) {
        final String cacheKey = ARTICLE_DETAIL_KEY + articleId;
        deleteOnce(cacheKey, articleId, phase, null);
        submitSecondDelete(articleId, phase, cacheKey);
    }

    /**
     * 提交一个第二删任务：接受、发布、开始执行、关闭、上限检查与终态共用同一把状态锁。
     *
     * <p>顺序保证：任务在调用 {@code schedule} <b>之前</b>就登记进活跃表并计入 accepted（都在锁内），
     * 工作线程把 QUEUED 改成 RUNNING 必须先拿同一把锁，所以「登记 + accepted 事件」一定先于
     * 「second_begin」；关闭同样在锁内接手，刚入队、还在交接中的任务不会被漏掉。
     * 进入终态时也在锁内移出活跃表，终态对象不可能再被写回。</p>
     *
     * <p>上限：{@code max_active = queued + running}，即活跃表大小。检查、登记与释放都在同一把锁内，
     * 因此并发提交不会突破上限；超限只拒第二删（第一删已执行），计数进 {@code rejected_backlog}，
     * 不进入活跃表，也没有任何隐藏队列。终态释放名额只发生一次（终态只写一次、同锁内移除）。</p>
     */
    private void submitSecondDelete(Long articleId, String phase, String cacheKey) {
        final String taskId = taskIdPrefix + GLOBAL_TASK_SEQ.incrementAndGet();
        synchronized (stateLock) {
            submitAttempts.incrementAndGet();
            if (closing.get()) {
                rejectedClosed.incrementAndGet();
                probe.event("cache.evict.second_rejected", 0L, articleId,
                        "taskId=" + taskId + " phase=" + phase + " reason=closed key=" + cacheKey);
                log.warn("失效器正在关闭，拒绝新的延迟删除: articleId={}, taskId={}", articleId, taskId);
                return;
            }
            if (activeTasks.size() >= maxActive) {
                //超限：只拒第二删，第一删已经执行过，已提交的写入结果不受影响
                rejectedBacklog.incrementAndGet();
                probe.event("cache.evict.second_rejected", 0L, articleId,
                        "taskId=" + taskId + " phase=" + phase + " reason=backlog maxActive=" + maxActive
                                + " active=" + activeTasks.size() + " peak=" + activePeak + " key=" + cacheKey);
                log.warn("第二删活跃任务已达上限，拒绝本次安排（第一删已执行）: articleId={}, taskId={}, maxActive={}, active={}",
                        articleId, taskId, maxActive, activeTasks.size());
                return;
            }
            SecondDeleteTask task = new SecondDeleteTask(taskId, articleId, phase, cacheKey,
                    System.currentTimeMillis());
            //先发布再调度：执行线程拿不到锁就不能进入 RUNNING，因此不会出现“先跑完、后发布”
            activeTasks.put(taskId, task);
            if (activeTasks.size() > activePeak) {
                activePeak = activeTasks.size();
            }
            try {
                task.future = secondDeleteScheduler.schedule(() -> runSecondDelete(task),
                        SECOND_DELETE_DELAY_MILLIS, TimeUnit.MILLISECONDS);
            } catch (RuntimeException e) {
                //调度失败不算接受：撤回登记（名额随之释放），只记一条带原因的拒绝
                activeTasks.remove(taskId);
                rejectedScheduler.incrementAndGet();
                probe.event("cache.evict.second_rejected", 0L, articleId,
                        "taskId=" + taskId + " phase=" + phase + " reason=scheduler error="
                                + e.getClass().getSimpleName() + " key=" + cacheKey);
                log.warn("延迟删除详情缓存未能安排, articleId={}, taskId={}, error={}", articleId, taskId, e.getMessage());
                return;
            }
            accepted.incrementAndGet();
            probe.event("cache.evict.second_scheduled", 0L, articleId,
                    "taskId=" + taskId + " phase=" + phase + " delayMs=" + SECOND_DELETE_DELAY_MILLIS
                            + " active=" + activeTasks.size() + " maxActive=" + maxActive + " key=" + cacheKey);
            probe.event("cache.evict.second_accepted", 0L, articleId,
                    "taskId=" + taskId + " phase=" + phase + " state=" + task.state
                            + " active=" + activeTasks.size() + " peak=" + activePeak + " key=" + cacheKey);
        }
    }

    /**
     * 任务真正开始执行：QUEUED→RUNNING 也在状态锁里完成，已取消或已终态的任务不会复活，
     * 也不会有第二次 begin / 第二个终态。
     */
    private void runSecondDelete(SecondDeleteTask task) {
        synchronized (stateLock) {
            if (task.state != TaskState.QUEUED) {
                //已被关闭取消（或已进入终态）：不执行 I/O，也不写第二个终态
                return;
            }
            task.state = TaskState.RUNNING;
            task.startedAtMs = System.currentTimeMillis();
            started.incrementAndGet();
        }
        probe.event("cache.evict.second_begin", 0L, task.articleId,
                "taskId=" + task.taskId + " phase=" + task.phase + " state=" + TaskState.RUNNING + " key=" + task.cacheKey);

        long slow = probe.secondDeleteSlowMillis(task.articleId);
        if (slow > 0L) {
            probe.event("cache.evict.second_pause_begin", 0L, task.articleId,
                    "taskId=" + task.taskId + " phase=" + task.phase + " pauseMs=" + slow);
            try {
                Thread.sleep(slow);
            } catch (InterruptedException ie) {
                Thread.currentThread().interrupt();
                finish(task, TaskState.CANCELLED, "interrupted_during_pause");
                return;
            }
            probe.event("cache.evict.second_pause_end", 0L, task.articleId,
                    "taskId=" + task.taskId + " phase=" + task.phase + " pauseMs=" + slow);
        }

        boolean ok = deleteOnce(task.cacheKey, task.articleId, task.phase + ":second", task.taskId);
        finish(task, ok ? TaskState.SUCCEEDED : TaskState.FAILED, ok ? "deleted" : "delete_failed");
    }

    /**
     * 写终态：只允许一次，且与发布/开始/取消共用 {@code stateLock}。
     * 进入终态时在锁内把任务移出活跃表并累加对应计数，因此终态对象不会被重新放回活跃表。
     */
    private void finish(SecondDeleteTask task, TaskState target, String outcome) {
        synchronized (stateLock) {
            if (task.state == TaskState.SUCCEEDED || task.state == TaskState.FAILED
                    || task.state == TaskState.CANCELLED) {
                return;
            }
            task.state = target;
            task.outcome = outcome;
            task.endedAtMs = System.currentTimeMillis();
            activeTasks.remove(task.taskId);
            long duration = task.startedAtMs > 0 ? (task.endedAtMs - task.startedAtMs) : -1L;
            if (target == TaskState.SUCCEEDED) {
                succeeded.incrementAndGet();
                probe.event("cache.evict.second_succeeded", 0L, task.articleId,
                        "taskId=" + task.taskId + " phase=" + task.phase + " outcome=" + outcome
                                + " runMs=" + duration + " key=" + task.cacheKey);
            } else if (target == TaskState.FAILED) {
                failedSecond.incrementAndGet();
                probe.event("cache.evict.second_failed", 0L, task.articleId,
                        "taskId=" + task.taskId + " phase=" + task.phase + " outcome=" + outcome
                                + " runMs=" + duration + " key=" + task.cacheKey);
            } else if (target == TaskState.CANCELLED) {
                cancelled.incrementAndGet();
                probe.event("cache.evict.second_cancelled", 0L, task.articleId,
                        "taskId=" + task.taskId + " phase=" + task.phase + " outcome=" + outcome
                                + " queueMs=" + (task.endedAtMs - task.acceptedAtMs) + " key=" + task.cacheKey);
            }
        }
    }

    /** 删除一次；故障夹具只在本轮配置了精确 articleId 的实例上生效 */
    private boolean deleteOnce(String cacheKey, Long articleId, String phase, String taskId) {
        deleteAttempts.incrementAndGet();
        String taskPart = taskId == null ? "" : " taskId=" + taskId;
        probe.event("cache.evict.begin", 0L, articleId,
                "phase=" + phase + taskPart + " key=" + cacheKey);
        try {
            maybeInjectFault(articleId, phase, taskId);
            cacheService.delete(cacheKey);
            probe.event("cache.evict.ok", 0L, articleId,
                    "phase=" + phase + taskPart + " key=" + cacheKey);
            return true;
        } catch (RuntimeException e) {
            deleteFailures.incrementAndGet();
            probe.event("cache.evict.fail", 0L, articleId,
                    "phase=" + phase + taskPart + " key=" + cacheKey + " error=" + e.getClass().getSimpleName()
                            + " message=" + String.valueOf(e.getMessage()).replace(' ', '_'));
            log.warn("删除文章详情缓存失败（写入已按事务结果处理，不因此回滚）, key={}, phase={}, error={}",
                    cacheKey, phase, e.getMessage());
            return false;
        }
    }

    /**
     * 故障注入：第一删用 {@code fault.cache.evict.<id>}，第二删另外支持
     * {@code fault.cache.evict.second.<id>}，两者都只影响配置中精确指定的 articleId。
     */
    private void maybeInjectFault(Long articleId, String phase, String taskId) {
        boolean second = phase != null && phase.endsWith(":second");
        if (second) {
            String mode = probe.secondDeleteFaultMode(articleId);
            if ("always".equals(mode)) {
                probe.event("fault.cache.evict.injected", 0L, articleId,
                        "phase=" + phase + " mode=always scope=second taskId=" + (taskId == null ? "-" : taskId));
                throw new RedisConnectionFailureException(
                        "P1.3c-1 simulated SECOND cache delete failure (always) at " + phase);
            }
            if ("once".equals(mode) && "first".equals(secondAttemptMarker(articleId))) {
                probe.event("fault.cache.evict.injected", 0L, articleId,
                        "phase=" + phase + " mode=once scope=second taskId=" + (taskId == null ? "-" : taskId));
                throw new RedisConnectionFailureException(
                        "P1.3c-1 simulated SECOND cache delete failure (once) at " + phase);
            }
            return;
        }
        String mode = probe.evictFaultMode(articleId);
        if ("always".equals(mode)) {
            probe.event("fault.cache.evict.injected", 0L, articleId, "phase=" + phase + " mode=always");
            throw new RedisConnectionFailureException("P1.3a simulated cache delete failure (always) at " + phase);
        }
        if ("once".equals(mode) && "first".equals(firstAttemptMarker(articleId))) {
            probe.event("fault.cache.evict.injected", 0L, articleId, "phase=" + phase + " mode=once");
            throw new RedisConnectionFailureException("P1.3a simulated cache delete failure (once) at " + phase);
        }
    }

    /**
     * "once" 只对某个 articleId 的第一次删除尝试生效：第一次调用返回 first，之后返回 later。
     * 用进程内集合记录，避免第二次删除也被同一个故障吃掉。
     */
    private final java.util.Set<String> firstAttemptSeen =
            java.util.Collections.newSetFromMap(new ConcurrentHashMap<String, Boolean>());

    /** 第二删的 "once"：对该 articleId 的第一个第二删任务生效一次 */
    private final java.util.Set<String> secondAttemptSeen =
            java.util.Collections.newSetFromMap(new ConcurrentHashMap<String, Boolean>());

    private String firstAttemptMarker(Long articleId) {
        return firstAttemptSeen.add(String.valueOf(articleId)) ? "first" : "later";
    }

    private String secondAttemptMarker(Long articleId) {
        return secondAttemptSeen.add(String.valueOf(articleId)) ? "first" : "later";
    }

    private static String statusName(int status) {
        switch (status) {
            case TransactionSynchronization.STATUS_COMMITTED:
                return "COMMITTED";
            case TransactionSynchronization.STATUS_ROLLED_BACK:
                return "ROLLED_BACK";
            case TransactionSynchronization.STATUS_UNKNOWN:
                return "UNKNOWN";
            default:
                return "STATUS_" + status;
        }
    }

    /** 活跃表里某状态的任务数量（活跃表只保留排队/运行中的任务） */
    private int count(TaskState state) {
        int n = 0;
        for (SecondDeleteTask t : activeTasks.values()) {
            if (t.state == state) {
                n++;
            }
        }
        return n;
    }

    /**
     * 关闭尚未执行的任务：取消调度并写终态 CANCELLED。已经在运行的 I/O 不被中断，
     * 它会在自己结束时写自己的终态（关闭回执不替它宣布成功或失败）。
     *
     * <p>不变量：执行器已经终止时，仍处于 QUEUED 的任务永远不会再被执行，
     * 因此一律登记为取消（带 {@code _never_ran}/{@code _by_executor} 说明），
     * 不会留下“已取消但仍在活跃表”或“排队却永不执行”的残留。</p>
     */
    private int cancelQueuedTasks(String reason, boolean executorTerminated) {
        synchronized (stateLock) {
            int n = 0;
            List<SecondDeleteTask> snapshot = new ArrayList<>(activeTasks.values());
            for (SecondDeleteTask t : snapshot) {
                if (t.state != TaskState.QUEUED) {
                    continue;
                }
                ScheduledFuture<?> f = t.future;
                //shutdown 之后执行器本身也不再执行已排队的延迟任务（policy=false），两种取消都算取消
                boolean cancelledByUs = f != null && f.cancel(false);
                boolean cancelledByExecutor = f != null && f.isCancelled();
                if (cancelledByUs || cancelledByExecutor) {
                    finish(t, TaskState.CANCELLED, cancelledByUs ? reason : reason + "_by_executor");
                    n++;
                } else if (executorTerminated) {
                    //执行器已终止且这个任务没被标记取消：它同样永远不会执行，按取消登记，避免残留
                    finish(t, TaskState.CANCELLED, reason + "_never_ran");
                    n++;
                } else {
                    probe.event("cache.evict.second_cancel_pending", 0L, t.articleId,
                            "taskId=" + t.taskId + " phase=" + t.phase + " state=" + t.state + " reason=" + reason);
                }
            }
            return n;
        }
    }

    /**
     * 真实的 Spring 生命周期钩子（{@link DisposableBean}）：关闭本组件自己创建的调度器。
     *
     * <p>顺序固定：先把 closing 置真（此后新提交一律拒绝）→ shutdown（不再接受任务，且不执行已排队的延迟任务）
     * → 有界等待 → 取消仍未执行的任务并计取消 → 写关闭回执。等待到期时仍在运行的 I/O 不会被强写成功或失败，
     * 它的终态由它自己在结束时记录。</p>
     */
    @Override
    public void destroy() {
        long begin = System.currentTimeMillis();
        int queuedAtStart;
        int runningAtStart;
        //1) 在锁内关闭入口：此后到达的提交一律拒绝，刚入队但尚未开始的任务也一定能被接手
        synchronized (stateLock) {
            if (!closing.compareAndSet(false, true)) {
                return;
            }
            queuedAtStart = count(TaskState.QUEUED);
            runningAtStart = count(TaskState.RUNNING);
            closeQueuedAtStart = queuedAtStart;
            closeRunningAtStart = runningAtStart;
            probe.event("cache.evict.shutdown_begin", 0L, 0L,
                    "waitMs=" + closeWaitMillis + " queued=" + queuedAtStart + " running=" + runningAtStart
                            + " accepted=" + accepted.get() + " thread=" + Thread.currentThread().getName());
            secondDeleteScheduler.shutdown();
        }
        //2) 有界等待：不持锁，否则运行中的任务无法写终态
        boolean terminated = false;
        try {
            terminated = secondDeleteScheduler.awaitTermination(closeWaitMillis, TimeUnit.MILLISECONDS);
        } catch (InterruptedException ie) {
            Thread.currentThread().interrupt();
        }
        closeWaitedMillis = System.currentTimeMillis() - begin;
        closeTerminated = terminated;

        //3) 收尾也在锁内：取消/登记仍未执行的任务，再写回执，计数与活跃集合不会与提交/终态交错
        int cancelledNow;
        synchronized (stateLock) {
            cancelledNow = cancelQueuedTasks(terminated ? "close" : "close_timeout", terminated);
            closeCancelledCount = cancelledNow;
            closeFinished = true;
            int queuedLeft = count(TaskState.QUEUED);
            int runningLeft = count(TaskState.RUNNING);
            probe.event("cache.evict.shutdown_end", 0L, 0L,
                    "waitedMs=" + closeWaitedMillis + " waitMs=" + closeWaitMillis + " terminated=" + terminated
                            + " cancelled=" + cancelledNow + " queuedBefore=" + queuedAtStart
                            + " runningBefore=" + runningAtStart + " queuedAfter=" + queuedLeft
                            + " runningAfter=" + runningLeft + " succeeded=" + succeeded.get()
                            + " failed=" + failedSecond.get() + " cancelledTotal=" + cancelled.get()
                            + " activeAfter=" + activeTasks.size());
        }
        log.warn("详情缓存失效器关闭: waitedMs={}, terminated={}, cancelled={}, queuedBefore={}, runningBefore={}, activeAfter={}",
                closeWaitedMillis, terminated, cancelledNow, queuedAtStart, runningAtStart, activeTasks.size());
    }

    /** 只读计数，供实验接口/脚本核对；不参与业务判断。所有 *_ms 字段单位均为毫秒 */
    public Map<String, Object> stats() {
        Map<String, Object> m = new LinkedHashMap<>();
        // ---- 原有字段（保留兼容；second_delete_scheduled 现在只统计成功接受）
        m.put("delete_attempts", deleteAttempts.get());
        m.put("delete_failures", deleteFailures.get());
        m.put("second_delete_scheduled", accepted.get());
        m.put("second_delete_done", succeeded.get());
        m.put("second_delete_failures", failedSecond.get());
        m.put("after_commit_runs", afterCommitRuns.get());
        m.put("no_transaction_runs", noTransactionRuns.get());
        m.put("rollback_skips", rollbackSkips.get());
        m.put("second_delete_delay_ms", SECOND_DELETE_DELAY_MILLIS);
        // ---- P1.3c-1 提交与状态（累计，次）
        m.put("submit_attempts", submitAttempts.get());
        m.put("accepted", accepted.get());
        m.put("rejected", rejectedClosed.get() + rejectedScheduler.get() + rejectedBacklog.get());
        m.put("rejected_closed", rejectedClosed.get());
        m.put("rejected_scheduler", rejectedScheduler.get());
        m.put("rejected_backlog", rejectedBacklog.get());
        m.put("started", started.get());
        m.put("succeeded", succeeded.get());
        m.put("failed", failedSecond.get());
        m.put("cancelled", cancelled.get());
        // ---- 当前数量（活跃表里只有排队/运行中的任务）
        m.put("queued_now", count(TaskState.QUEUED));
        m.put("running_now", count(TaskState.RUNNING));
        m.put("active_now", activeTasks.size());
        // ---- 活跃上限（P1.3c-2）
        m.put("max_active", maxActive);
        m.put("active_peak", activePeak);
        // ---- 关闭回执
        m.put("closed", closing.get());
        m.put("close_finished", closeFinished);
        m.put("close_wait_ms", closeWaitMillis);
        m.put("close_waited_ms", closeWaitedMillis);
        m.put("close_terminated", closeTerminated);
        m.put("close_queued_before", closeQueuedAtStart);
        m.put("close_running_before", closeRunningAtStart);
        m.put("close_cancelled", closeCancelledCount);
        m.put("task_id_prefix", taskIdPrefix);
        return m;
    }
}
