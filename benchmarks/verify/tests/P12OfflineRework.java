import com.heima.article.service.impl.ApArticleServiceImpl;
import com.heima.article.support.DetailProbe;
import com.heima.common.redis.CacheService;
import com.heima.model.article.pojos.ApArticle;
import com.heima.model.common.dtos.ResponseResult;
import org.springframework.data.redis.RedisConnectionFailureException;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.data.redis.core.ValueOperations;

import java.io.Serializable;
import java.lang.reflect.Field;
import java.lang.reflect.InvocationHandler;
import java.lang.reflect.Method;
import java.lang.reflect.Proxy;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.TimeUnit;

/**
 * P1.2 rework offline harness (round 2, items R1 and R2).
 *
 * No Spring context, no Redis, no database, no HTTP: it drives the REAL compiled
 * ApArticleServiceImpl with test doubles, so the assertions are about the production
 * control flow rather than about a re-implementation of it.
 *
 * The same harness is run twice:
 *   - against the A baseline classes (pre-rework): the R1 counter-example must reproduce
 *     (a second lock attempt and a DAO call AFTER the budget was already spent)
 *   - against the B classes (reworked): the budget must bite, and every Redis failure must be
 *     classified by the code path it belongs to, not by a global exception handler
 *
 * Usage: java P12OfflineRework <case>   where case is one of
 *   R1-stall R1-late-acquire R1-slow-lock-fail R2-read R2-recheck R2-lock R2-release R2-slow-timeout R3-ok
 * Prints one line per assertion and exits 0 only if all of them pass.
 */
public class P12OfflineRework {

    // ---------- test doubles ----------
    static final class CountingService extends ApArticleServiceImpl {
        int dbCalls;
        @Override
        public ApArticle getById(Serializable id) {
            dbCalls++;
            return null; // "row does not exist" keeps the path short; a DAO call still happened
        }
    }

    static final class RecordingProbe extends DetailProbe {
        final List<String> events = new ArrayList<String>();
        long stallOnPreSleepMillis;
        boolean interruptOnce;

        // The stall is injected at wait.pre_sleep, which BOTH builds emit, so the fixture is
        // identical for A and B and the comparison is about the code, not about the harness.
        @Override
        public void event(String name, long req, long id, String extra) {
            events.add(name + (extra == null ? "" : (" " + extra)));
            if (stallOnPreSleepMillis > 0 && "wait.pre_sleep".equals(name)) {
                long stall = stallOnPreSleepMillis;
                stallOnPreSleepMillis = 0;
                try { Thread.sleep(stall); } catch (InterruptedException e) { Thread.currentThread().interrupt(); }
            }
        }

        @Override
        public boolean interruptConfiguredFor(long articleId) {
            return interruptOnce;
        }

        // the probe's own injection is deliberately NOT used: R2 requires the failure to come from
        // the real I/O operation so the classification under test is the production one
        @Override
        public void failRedisIfConfigured(String stage, long reqId, long articleId) { }

        boolean sawEvent(String name) {
            for (String e : events) { if (e.startsWith(name)) { return true; } }
            return false;
        }
        String eventWith(String name) {
            for (String e : events) { if (e.startsWith(name)) { return e; } }
            return "";
        }
    }


    static final class FailingCache extends CacheService {
        int getCalls, lockAttempts, releases;
        boolean failRead, failRecheck, failLock, failRelease;
        long lockSleepMillis;      // makes the SET NX arrive late
        long slowReadMillis;       // simulates a sluggish command that then times out
        boolean lockGranted = true;
        final ValueOperations<String, String> values;
        final StringRedisTemplate template;

        @SuppressWarnings("unchecked")
        FailingCache() {
            values = (ValueOperations<String, String>) Proxy.newProxyInstance(
                    ValueOperations.class.getClassLoader(),
                    new Class<?>[]{ValueOperations.class},
                    new InvocationHandler() {
                        public Object invoke(Object p, Method m, Object[] a) {
                            if (!"setIfAbsent".equals(m.getName())) {
                                throw new UnsupportedOperationException(m.getName());
                            }
                            lockAttempts++;
                            if (lockSleepMillis > 0) {
                                try { Thread.sleep(lockSleepMillis); } catch (InterruptedException e) { Thread.currentThread().interrupt(); }
                            }
                            if (failLock) { throw new RedisConnectionFailureException("offline real SET NX failure"); }
                            return Boolean.valueOf(lockGranted && lockAttempts == 1);
                        }
                    });
            template = new StringRedisTemplate() {
                @Override public ValueOperations<String, String> opsForValue() { return values; }
            };
        }

        @Override
        public String get(String key) {
            getCalls++;
            if (getCalls == 1 && slowReadMillis > 0) {
                try { Thread.sleep(slowReadMillis); } catch (InterruptedException e) { Thread.currentThread().interrupt(); }
                throw new RedisConnectionFailureException("offline real GET timed out");
            }
            if (failRead && getCalls == 1) { throw new RedisConnectionFailureException("offline real GET failure"); }
            if (failRecheck && getCalls > 1) { throw new RedisConnectionFailureException("offline real recheck failure"); }
            return null;
        }

        @Override
        public StringRedisTemplate getstringRedisTemplate() { return template; }

        @Override
        public Long releaseIfValueEquals(String key, String expected) {
            if (failRelease) { throw new RedisConnectionFailureException("offline real release failure"); }
            releases++;
            return 1L;
        }

        @Override
        public void setEx(String key, String value, long timeout, TimeUnit unit) { }
    }

    // ---------- wiring ----------
    static void set(Object target, String name, Object value) throws Exception {
        Field f = ApArticleServiceImpl.class.getDeclaredField(name);
        f.setAccessible(true);
        f.set(target, value);
    }

    static CountingService service(FailingCache cache, RecordingProbe probe, long budgetMillis) throws Exception {
        CountingService s = new CountingService();
        set(s, "cacheService", cache);
        set(s, "probe", probe);
        set(s, "objectMapper", new com.fasterxml.jackson.databind.ObjectMapper());
        set(s, "articleDetailCacheEnabled", true);
        set(s, "articleDetailExpireSeconds", 1800L);
        set(s, "articleDetailNullExpireSeconds", 60L);
        set(s, "articleDetailExpireJitterSeconds", 0L);
        set(s, "lockExpireMillis", 3000L);
        set(s, "lockWaitBudgetMillis", budgetMillis);
        set(s, "lockWaitBackoffMillis", 10L);
        set(s, "lockWaitBackoffMaxMillis", 50L);
        return s;
    }

    static int code(ResponseResult r) {
        return r == null || r.getCode() == null ? -1 : r.getCode().intValue();
    }

    static int failures = 0;

    static void check(String name, boolean ok, String detail) {
        System.out.println((ok ? "[PASS] " : "[FAIL] ") + name + " :: " + detail);
        if (!ok) { failures++; }
    }

    public static void main(String[] args) throws Exception {
        String c = args.length > 0 ? args[0] : "R3-ok";
        long id = 9007199254741001L;

        if ("R1-stall".equals(c)) {
            // budget 100 ms; the wait loop is stalled 150 ms after its first sleep
            FailingCache cache = new FailingCache();
            cache.lockGranted = false;             // first attempt fails, so a retry would be attempted
            RecordingProbe probe = new RecordingProbe();
            probe.stallOnPreSleepMillis = 150L;
            CountingService s = service(cache, probe, 100L);
            ResponseResult r = s.getArticleDetail(id);
            check("R1.stall.no_second_lock_attempt", cache.lockAttempts == 1,
                    "lock attempts=" + cache.lockAttempts + " (budget 100 ms, stall 150 ms)");
            check("R1.stall.no_dao_after_budget", s.dbCalls == 0, "db calls=" + s.dbCalls);
            check("R1.stall.explicit_503", code(r) == 503, "biz code=" + code(r));
            check("R1.stall.budget_phase", probe.eventWith("wait.end").contains("budget_exhausted"),
                    probe.eventWith("wait.end"));
        } else if ("R1-late-acquire".equals(c)) {
            // budget 100 ms; SET NX takes 150 ms and then succeeds -> the token must be cleaned up
            FailingCache cache = new FailingCache();
            cache.lockSleepMillis = 150L;
            RecordingProbe probe = new RecordingProbe();
            CountingService s = service(cache, probe, 100L);
            ResponseResult r = s.getArticleDetail(id);
            check("R1.late.no_dao", s.dbCalls == 0, "db calls=" + s.dbCalls);
            check("R1.late.explicit_503", code(r) == 503, "biz code=" + code(r));
            check("R1.late.token_released_once", cache.releases == 1, "releases=" + cache.releases);
            check("R1.late.event_recorded", probe.sawEvent("lock.late_acquire"), probe.eventWith("lock.late_acquire"));
        } else if ("R1-slow-lock-fail".equals(c)) {
            // R1 tail branch (round-3 review): budget 100 ms; SET NX is issued INSIDE the budget but the
            // call itself takes 150 ms and then returns false. The recheck GET after it must not be issued
            // at all: getCalls stays 1 (only the initial read), no io.begin stage=recheck, no DAO.
            FailingCache cache = new FailingCache();
            cache.lockGranted = false;
            cache.lockSleepMillis = 150L;
            RecordingProbe probe = new RecordingProbe();
            CountingService s = service(cache, probe, 100L);
            ResponseResult r = s.getArticleDetail(id);
            int recheckBegins = 0;
            for (String e : probe.events) {
                if (e.startsWith("io.begin") && e.contains("stage=recheck")) { recheckBegins++; }
            }
            check("R1.slowfail.get_calls_only_the_first_read", cache.getCalls == 1,
                    "get calls=" + cache.getCalls + " (expected 1: the initial read only)");
            check("R1.slowfail.no_recheck_io", recheckBegins == 0,
                    "io.begin stage=recheck=" + recheckBegins + " (a slow lock failure must not buy another Redis I/O)");
            check("R1.slowfail.single_lock_attempt", cache.lockAttempts == 1, "lock attempts=" + cache.lockAttempts);
            check("R1.slowfail.no_dao", s.dbCalls == 0, "db calls=" + s.dbCalls);
            check("R1.slowfail.explicit_503", code(r) == 503, "biz code=" + code(r));
            check("R1.slowfail.phase_before_recheck", probe.eventWith("wait.end").contains("phase=before_recheck"),
                    probe.eventWith("wait.end"));
        } else if ("R2-read".equals(c)) {
            FailingCache cache = new FailingCache();
            cache.failRead = true;
            RecordingProbe probe = new RecordingProbe();
            CountingService s = service(cache, probe, 1000L);
            ResponseResult r = s.getArticleDetail(id);
            check("R2.read.no_dao", s.dbCalls == 0, "db calls=" + s.dbCalls);
            check("R2.read.explicit_503", code(r) == 503, "biz code=" + code(r));
            check("R2.read.classified_at_io", probe.eventWith("io.error").contains("stage=read"),
                    probe.eventWith("io.error"));
            check("R2.read.no_lock_attempt", cache.lockAttempts == 0, "lock attempts=" + cache.lockAttempts);
        } else if ("R2-recheck".equals(c)) {
            FailingCache cache = new FailingCache();
            cache.lockGranted = false;
            cache.failRecheck = true;
            RecordingProbe probe = new RecordingProbe();
            CountingService s = service(cache, probe, 300L);
            ResponseResult r = s.getArticleDetail(id);
            check("R2.recheck.classified", probe.sawEvent("io.error stage=recheck"),
                    probe.eventWith("io.error"));
            check("R2.recheck.no_dao", s.dbCalls == 0, "db calls=" + s.dbCalls);
            check("R2.recheck.explicit_503", code(r) == 503, "biz code=" + code(r));
        } else if ("R2-lock".equals(c)) {
            FailingCache cache = new FailingCache();
            cache.failLock = true;
            RecordingProbe probe = new RecordingProbe();
            CountingService s = service(cache, probe, 1000L);
            ResponseResult r = s.getArticleDetail(id);
            check("R2.lock.classified_at_io", probe.eventWith("io.error").contains("stage=lock"),
                    probe.eventWith("io.error"));
            check("R2.lock.no_dao", s.dbCalls == 0, "db calls=" + s.dbCalls);
            check("R2.lock.explicit_503", code(r) == 503, "biz code=" + code(r));
        } else if ("R2-release".equals(c)) {
            FailingCache cache = new FailingCache();
            cache.failRelease = true;
            RecordingProbe probe = new RecordingProbe();
            CountingService s = service(cache, probe, 1000L);
            ResponseResult r = s.getArticleDetail(id);
            check("R2.release.classified_at_io", probe.sawEvent("io.error stage=release"),
                    probe.eventWith("io.error"));
            check("R2.release.original_result_kept", code(r) == 1002,
                    "biz code=" + code(r) + " (the DAO said the row is missing; a release failure must not change it)");
            check("R2.release.dao_happened", s.dbCalls == 1, "db calls=" + s.dbCalls);
        } else if ("R2-slow-timeout".equals(c)) {
            FailingCache cache = new FailingCache();
            cache.slowReadMillis = 300L;
            RecordingProbe probe = new RecordingProbe();
            CountingService s = service(cache, probe, 100L);
            ResponseResult r = s.getArticleDetail(id);
            String ioErr = probe.eventWith("io.error");
            long elapsed = -1;
            java.util.regex.Matcher m = java.util.regex.Pattern.compile("elapsedMs=(\\d+)").matcher(ioErr);
            if (m.find()) { elapsed = Long.parseLong(m.group(1)); }
            check("R2.slow.single_io_exceeds_budget", elapsed >= 250L,
                    "io elapsedMs=" + elapsed + " while the loop budget is 100 ms (I/O timeout is a separate bound)");
            check("R2.slow.explicit_503", code(r) == 503, "biz code=" + code(r));
            check("R2.slow.no_dao", s.dbCalls == 0, "db calls=" + s.dbCalls);
        } else {
            // R3-ok: the happy path still works after the rework
            FailingCache cache = new FailingCache();
            RecordingProbe probe = new RecordingProbe();
            CountingService s = service(cache, probe, 1000L);
            ResponseResult r = s.getArticleDetail(id);
            check("ok.first_attempt_taken", cache.lockAttempts == 1, "lock attempts=" + cache.lockAttempts);
            check("ok.dao_called_once", s.dbCalls == 1, "db calls=" + s.dbCalls);
            check("ok.released_once", cache.releases == 1, "releases=" + cache.releases);
            check("ok.biz_code", code(r) == 1002, "biz code=" + code(r));
        }

        System.out.println(failures == 0 ? "RESULT=ALL_PASS" : ("RESULT=FAILURES=" + failures));
        System.exit(failures == 0 ? 0 : 1);
    }
}
