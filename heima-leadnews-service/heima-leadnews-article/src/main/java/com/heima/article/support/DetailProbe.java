package com.heima.article.support;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Component;
import org.springframework.web.context.request.RequestAttributes;
import org.springframework.web.context.request.RequestContextHolder;
import org.springframework.web.context.request.ServletRequestAttributes;

import javax.servlet.http.HttpServletRequest;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.nio.file.StandardOpenOption;
import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.Properties;
import java.util.concurrent.TimeUnit;

/**
 * P1.2 实验用探针（instrumentation baseline）。
 *
 * <p><b>默认完全关闭</b>：只有启动参数 {@code -Darticle.detail.probe.file=<path>} 指向一个可读的
 * properties 文件时才生效；未设置该参数、文件不存在或解析失败时，所有方法立即返回，不写文件、
 * 不睡眠、不注入异常。它不是一个对外接口，也没有任何 HTTP 入口，控制器与接口签名均未改动。</p>
 *
 * <p>为什么需要它：P1.2 要证明「固定值锁被旧持有者误删」和「50ms 后无约束回源放大」，
 * 就必须能在同一份代码上分别取修前/修后证据，并且用同一套夹具与打点。因此本类在修复前先加入、
 * 修复后不再改动；修前/修后两次运行的探针类与配置项保持一致，只有锁实现本身不同。</p>
 *
 * <p>支持的配置项（properties 文件，按 articleId 精确匹配）：</p>
 * <ul>
 *   <li>{@code events.file=<path>} 事件流水文件（追加写，一行一个事件）</li>
 *   <li>{@code db.delay.<articleId>=<millis>} 在回源的 DAO 调用前睡眠，模拟慢 DB</li>
 *   <li>{@code wait.interrupt.<articleId>=true} 在等待循环的某一次迭代中对当前线程发中断</li>
 *   <li>{@code fault.redis.<stage>=<read|lock|release>} 在该步骤抛出 Redis 连接异常（模拟故障）</li>
 *   <li>{@code lock.hold.<articleId>=<millis>} 获锁后额外持有时长，用于「持锁超过租期」场景</li>
 * </ul>
 *
 * <p>所有注入都只在设置了上述系统参数的实例里发生，默认运行不带延迟、不带异常、不暴露控制入口。</p>
 */
@Component
public class DetailProbe {

    private static final Logger log = LoggerFactory.getLogger(DetailProbe.class);

    /** 开启探针的系统参数名；未设置即关闭 */
    public static final String PROBE_FILE_PROPERTY = "article.detail.probe.file";

    private static final String UNKNOWN = "-";

    private final boolean enabled;
    private final Path eventsFile;
    private final Properties config = new Properties();
    private final Object writeLock = new Object();
    private final String pid;

    public DetailProbe() {
        String cfgPath = System.getProperty(PROBE_FILE_PROPERTY);
        Path events = null;
        boolean ok = false;
        if (cfgPath != null && !cfgPath.trim().isEmpty()) {
            try {
                Path p = Paths.get(cfgPath.trim());
                if (Files.isReadable(p)) {
                    try (java.io.InputStream in = Files.newInputStream(p)) {
                        config.load(in);
                    }
                    String ev = config.getProperty("events.file");
                    if (ev != null && !ev.trim().isEmpty()) {
                        events = Paths.get(ev.trim());
                        Files.createDirectories(events.getParent());
                        ok = true;
                    }
                }
            } catch (Exception e) {
                ok = false;
                log.warn("[DETAIL-PROBE] disabled, cannot load config {}: {}", cfgPath, e.toString());
            }
        }
        this.enabled = ok;
        this.eventsFile = events;
        this.pid = currentPid();
        if (this.enabled) {
            log.warn("[DETAIL-PROBE] ENABLED (experiment only), config={}, events={}", cfgPath, events);
            event("probe.enabled", 0L, 0L, "config=" + cfgPath);
        }
    }

    public boolean isEnabled() {
        return enabled;
    }

    private static String currentPid() {
        try {
            String name = java.lang.management.ManagementFactory.getRuntimeMXBean().getName();
            int at = name.indexOf('@');
            return at > 0 ? name.substring(0, at) : name;
        } catch (Throwable t) {
            return UNKNOWN;
        }
    }

    public String getPid() {
        return pid;
    }

    /** 实验请求自带的 run_id / request_id（HTTP 头，缺失时为 "-"），由采集脚本注入 */
    private static String header(String name) {
        try {
            RequestAttributes attrs = RequestContextHolder.getRequestAttributes();
            if (attrs instanceof ServletRequestAttributes) {
                HttpServletRequest req = ((ServletRequestAttributes) attrs).getRequest();
                String v = req.getHeader(name);
                return v == null || v.isEmpty() ? UNKNOWN : v;
            }
        } catch (Throwable ignored) {
            // 非 HTTP 线程（单元测试/定时任务）没有请求上下文，按未知处理
        }
        return UNKNOWN;
    }

    /**
     * 写一行事件。字段固定为 ts/epochMs/pid/thread/runId/requestId/event/reqId/articleId + 额外 kv，
     * 便于跨进程按 epochMs 汇总区间。
     */
    public void event(String name, long reqId, long articleId, String extra) {
        if (!enabled) {
            return;
        }
        StringBuilder sb = new StringBuilder(192);
        long now = System.currentTimeMillis();
        sb.append("ts=").append(new SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSSZ").format(new Date(now)))
                .append(" epochMs=").append(now)
                .append(" pid=").append(pid)
                .append(" thread=").append(Thread.currentThread().getName())
                .append(" runId=").append(header("X-P1-Run-Id"))
                .append(" requestId=").append(header("X-P1-Request-Id"))
                .append(" event=").append(name)
                .append(" reqId=").append(reqId)
                .append(" articleId=").append(articleId);
        if (extra != null && !extra.isEmpty()) {
            sb.append(' ').append(extra);
        }
        sb.append(System.lineSeparator());
        try {
            synchronized (writeLock) {
                Files.write(eventsFile, sb.toString().getBytes(StandardCharsets.UTF_8),
                        StandardOpenOption.CREATE, StandardOpenOption.APPEND);
            }
        } catch (IOException e) {
            log.warn("[DETAIL-PROBE] cannot write event {}: {}", name, e.toString());
        }
    }

    private long longFor(String prefix, long articleId, long dflt) {
        String v = config.getProperty(prefix + articleId);
        if (v == null) {
            return dflt;
        }
        try {
            long parsed = Long.parseLong(v.trim());
            return parsed >= 0 ? parsed : dflt;
        } catch (NumberFormatException e) {
            return dflt;
        }
    }

    private boolean flag(String prefix, long articleId) {
        String v = config.getProperty(prefix + articleId);
        return v != null && "true".equalsIgnoreCase(v.trim());
    }

    /** 回源前的受控 DB 延迟（毫秒）；未配置返回 0 */
    public long dbDelayMillis(long articleId) {
        return enabled ? longFor("db.delay.", articleId, 0L) : 0L;
    }

    /** 获锁后额外持有时长（毫秒），用于构造「持锁超过租期」；未配置返回 0 */
    public long lockHoldMillis(long articleId) {
        return enabled ? longFor("lock.hold.", articleId, 0L) : 0L;
    }

    /**
     * 模拟 Redis 故障：stage 取 read / recheck / lock / recheck_after_lock / release。
     * 只在本轮实例的测试配置里生效，用于覆盖各 I/O 分支的失败处理，不是真实依赖故障。
     *
     * <p>支持两种注入：
     * <ul>
     *   <li>{@code fault.redis.<stage>=true} —— 立即抛连接失败</li>
     *   <li>{@code fault.redis.timeout.<stage>=<millis>} —— 先"慢"指定毫秒（模拟命令迟滞），再抛超时类失败，
     *       用于验证「单次 I/O 可能超出循环预算」这一边界</li>
     * </ul>
     */
    public void failRedisIfConfigured(String stage, long reqId, long articleId) {
        if (!enabled) {
            return;
        }
        String timeout = config.getProperty("fault.redis.timeout." + stage);
        if (timeout != null && !timeout.trim().isEmpty()) {
            long slowMillis;
            try {
                slowMillis = Math.max(0L, Long.parseLong(timeout.trim()));
            } catch (NumberFormatException e) {
                slowMillis = 0L;
            }
            event("fault.redis.injected", reqId, articleId,
                    "stage=" + stage + " kind=slow_timeout plannedSlowMs=" + slowMillis);
            try {
                Thread.sleep(slowMillis);
            } catch (InterruptedException ie) {
                Thread.currentThread().interrupt();
            }
            throw new org.springframework.data.redis.RedisConnectionFailureException(
                    "P1.2 simulated redis TIMEOUT at " + stage + " after " + slowMillis + "ms");
        }
        String v = config.getProperty("fault.redis." + stage);
        if (v == null || !"true".equalsIgnoreCase(v.trim())) {
            return;
        }
        event("fault.redis.injected", reqId, articleId, "stage=" + stage + " kind=immediate");
        throw new org.springframework.data.redis.RedisConnectionFailureException(
                "P1.2 simulated redis failure at " + stage);
    }

    /**
     * R1 夹具：在等待循环的睡眠之后、下一次争锁之前插入一次调度停顿（毫秒），
     * 用于复现「预算已被停顿吃掉，但旧实现仍会再次争锁」的场景。
     *
     * @return 实际停顿毫秒，0 表示未配置
     */
    public long stallIfConfigured(long articleId, long reqId) {
        if (!enabled) {
            return 0L;
        }
        long ms = longFor("wait.stall.", articleId, 0L);
        if (ms <= 0) {
            return 0L;
        }
        event("wait.stall.begin", reqId, articleId, "stallMs=" + ms);
        try {
            Thread.sleep(ms);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
        event("wait.stall.end", reqId, articleId, "stallMs=" + ms);
        return ms;
    }

    /** 受控睡眠：被中断时恢复标记并抛出，调用方决定如何收尾 */
    public void sleep(long millis) {
        if (millis <= 0) {
            return;
        }
        try {
            Thread.sleep(millis);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new IllegalStateException("interrupted during simulated delay", e);
        }
    }

    /** 便于脚本核对：返回探针版本，写进 manifest */
    public String version() {
        return "p1-3a-probe-1";
    }

    /** 诊断用：当前 articleId 是否配置了等待中断注入（只读，不改变线程状态） */
    public boolean interruptConfiguredFor(long articleId) {
        return enabled && flag("wait.interrupt.", articleId);
    }

    /** 持有锁的模拟长耗时（用于「持有者阻塞超过租期」），睡眠期间不释放锁 */
    public void holdAfterLock(long articleId, long reqId) {
        long hold = lockHoldMillis(articleId);
        if (hold <= 0) {
            return;
        }
        event("lock.hold.begin", reqId, articleId, "holdMs=" + hold);
        sleep(hold);
        event("lock.hold.end", reqId, articleId, "holdMs=" + hold);
    }

    /** 单调时钟毫秒，供等待预算使用（避免受系统时间调整影响） */
    public static long monotonicMillis() {
        return TimeUnit.NANOSECONDS.toMillis(System.nanoTime());
    }

    // ================= P1.3a: transaction / post-commit fixture (all disabled by default) =================

    /**
     * Pre-commit barrier (ms): keeps the write transaction open before COMMIT, so another reader can
     * read the old version and refill the cache while the deletes have already happened but the commit
     * has not. Only active when {@code tx.hold.before-commit.<articleId>} is configured.
     */
    public void holdBeforeCommit(long articleId, long reqId) {
        if (!enabled) {
            return;
        }
        long ms = longFor("tx.hold.before-commit.", articleId, 0L);
        if (ms <= 0) {
            return;
        }
        event("tx.hold.begin", reqId, articleId, "holdMs=" + ms);
        sleep(ms);
        event("tx.hold.end", reqId, articleId, "holdMs=" + ms);
    }

    /**
     * Delay before the cache write (ms): pushes a reader's setEx to a chosen time after the commit so
     * the run can separate "inside the 500 ms second-delete window" from "beyond the window".
     * Only active when {@code cache.write.delay.<articleId>} is configured.
     */
    public long delayCacheWrite(long articleId, long reqId) {
        if (!enabled) {
            return 0L;
        }
        long ms = longFor("cache.write.delay.", articleId, 0L);
        if (ms <= 0) {
            return 0L;
        }
        event("cache.write.delay.begin", reqId, articleId, "delayMs=" + ms);
        sleep(ms);
        event("cache.write.delay.end", reqId, articleId, "delayMs=" + ms);
        return ms;
    }

    /** Controlled rollback: the writer throws after registering the invalidation (T2) */
    public boolean rollbackConfiguredFor(long articleId) {
        return enabled && flag("tx.rollback.", articleId);
    }

    /**
     * P1.3b: controlled rollback of the behaviour-count write (off by default). Active only when
     * {@code p13b.rollback.updateScore.<articleId>} is configured, and only for that article id:
     * updateScore has already written for real and registered the invalidation, then throws, so the
     * rollback must not delete the cache and the DB counters must not grow.
     */
    public boolean rollbackBehaviorCountConfiguredFor(long articleId) {
        return enabled && flag("p13b.rollback.updateScore.", articleId);
    }

    /**
     * P1.3c-1: 只作用在「第二删」上的失败注入（{@code none}/{@code once}/{@code always}），
     * 精确匹配 articleId。第一次删（立即删）不受影响，这样「第二删失败」可以被单独观察。
     */
    public String secondDeleteFaultMode(long articleId) {
        if (!enabled) {
            return "none";
        }
        String v = config.getProperty("fault.cache.evict.second." + articleId);
        if (v == null) {
            return "none";
        }
        return v.trim().toLowerCase();
    }

    /** P1.3c-1: 第二删的受控停顿（毫秒），只对精确 articleId 生效；0 表示不停顿 */
    public long secondDeleteSlowMillis(long articleId) {
        return enabled ? longFor("slow.cache.evict.second.", articleId, 0L) : 0L;
    }

    /**
     * P1.3c-1: 关闭等待窗口（毫秒）。取值顺序：探针配置 {@code p13c.evict.close-wait.ms} →
     * 传入的默认值。它只是工程配置，不是压测选出的参数。
     */
    public long closeWaitMillis(long dflt) {
        if (!enabled) {
            return dflt;
        }
        String v = config.getProperty("p13c.evict.close-wait.ms");
        if (v == null || v.trim().isEmpty()) {
            return dflt;
        }
        try {
            long parsed = Long.parseLong(v.trim());
            return parsed >= 0 ? parsed : dflt;
        } catch (NumberFormatException e) {
            return dflt;
        }
    }

    /**
     * Redis delete fault for the post-commit invalidation:
     * {@code none} (default) / {@code once} (first delete fails, the second is still scheduled) / {@code always}.
     * Only affects this instance and the exact articleId from the config file.
     */
    public String evictFaultMode(long articleId) {
        if (!enabled) {
            return "none";
        }
        String v = config.getProperty("fault.cache.evict." + articleId);
        if (v == null) {
            return "none";
        }
        return v.trim().toLowerCase();
    }

    // probe version from P1.3a on is p1-3a-probe-1 (the P1.2 value only appears in older handoffs)
}
