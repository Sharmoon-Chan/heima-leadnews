package com.heima.search.support;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.stereotype.Component;
import org.springframework.util.Assert;

import java.util.concurrent.TimeUnit;

/** Success markers only. There is intentionally no pre-ES claim or distributed lock. */
@Component
public class ArticleIndexSuccessMarkers {
    public enum State { HIT, MISS, UNAVAILABLE, DISABLED }
    public static final class Lookup {
        private final State state;
        private final long elapsedMicros;
        private final String failureType;
        private Lookup(State state, long elapsedMicros, String failureType) {
            this.state = state; this.elapsedMicros = elapsedMicros; this.failureType = failureType;
        }
        public State getState() { return state; }
        public long getElapsedMicros() { return elapsedMicros; }
        public String getFailureType() { return failureType; }
    }
    public static final class Write {
        private final boolean successful;
        private final long elapsedMicros;
        private final String failureType;
        private Write(boolean successful, long elapsedMicros, String failureType) {
            this.successful = successful; this.elapsedMicros = elapsedMicros; this.failureType = failureType;
        }
        public boolean isSuccessful() { return successful; }
        public long getElapsedMicros() { return elapsedMicros; }
        public String getFailureType() { return failureType; }
    }

    private final StringRedisTemplate redis;
    private final boolean enabled;
    private final String namespace;
    private final long ttlSeconds;

    public ArticleIndexSuccessMarkers(StringRedisTemplate redis,
            @Value("${leadnews.search.dedup.enabled:true}") boolean enabled,
            @Value("${leadnews.search.dedup.namespace:leadnews:search:processed:}") String namespace,
            @Value("${leadnews.search.dedup.ttl-seconds:86400}") long ttlSeconds) {
        Assert.hasText(namespace, "Dedup namespace must be nonblank");
        Assert.isTrue(ttlSeconds > 0, "Dedup success marker TTL must be positive");
        this.redis = redis; this.enabled = enabled; this.namespace = namespace; this.ttlSeconds = ttlSeconds;
    }

    public String key(String index, ArticleIndexMessage event) {
        return namespace + index + ":" + event.getEventId();
    }

    public Lookup lookup(String index, ArticleIndexMessage event) {
        if (!enabled || !event.isVersioned()) return new Lookup(State.DISABLED, 0, null);
        long start = System.nanoTime();
        String existing;
        try {
            existing = redis.opsForValue().get(key(index, event));
        } catch (RuntimeException failure) {
            return new Lookup(State.UNAVAILABLE, elapsed(start), failure.getClass().getSimpleName());
        }
        if (existing == null) return new Lookup(State.MISS, elapsed(start), null);
        if (!existing.equals(event.getMarkerValue()))
            throw new NonRetryableArticleSyncException("event-id-reused-with-different-payload");
        return new Lookup(State.HIT, elapsed(start), null);
    }

    /** Called after ES success only. Redis failure does not retroactively invalidate the ES result. */
    public Write markSuccessful(String index, ArticleIndexMessage event) {
        if (!enabled || !event.isVersioned()) return new Write(false, 0, "disabled");
        long start = System.nanoTime();
        try {
            redis.opsForValue().set(key(index, event), event.getMarkerValue(), ttlSeconds, TimeUnit.SECONDS);
            return new Write(true, elapsed(start), null);
        } catch (RuntimeException failure) {
            return new Write(false, elapsed(start), failure.getClass().getSimpleName());
        }
    }

    private static long elapsed(long start) { return (System.nanoTime() - start) / 1000L; }
}
