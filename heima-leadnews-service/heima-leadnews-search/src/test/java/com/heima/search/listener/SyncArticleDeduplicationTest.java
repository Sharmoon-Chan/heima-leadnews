package com.heima.search.listener;

import com.heima.search.support.ArticleIndexSuccessMarkers;
import com.heima.search.support.NonRetryableArticleSyncException;
import org.apache.kafka.clients.consumer.ConsumerRecord;
import org.elasticsearch.action.index.IndexRequest;
import org.elasticsearch.action.index.IndexResponse;
import org.elasticsearch.action.support.replication.ReplicationResponse;
import org.elasticsearch.index.shard.ShardId;
import org.junit.jupiter.api.Test;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.data.redis.core.ValueOperations;
import org.springframework.test.util.ReflectionTestUtils;

import java.io.IOException;
import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.TimeUnit;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;
import static org.mockito.ArgumentMatchers.*;

class SyncArticleDeduplicationTest {
    @FunctionalInterface
    interface IndexCall { void accept(IndexRequest request) throws IOException; }

    static class Listener extends SyncArticleListener {
        int calls;
        IndexCall action = request -> { };
        @Override IndexResponse index(IndexRequest request) throws IOException {
            calls++; action.accept(request);
            IndexResponse response=new IndexResponse(new ShardId("app_info_article","uuid",0),"_doc",request.id(),calls,1,calls,true);
            response.setShardInfo(new ReplicationResponse.ShardInfo(1,1));
            return response;
        }
    }

    static class Fixture {
        final StringRedisTemplate redis=mock(StringRedisTemplate.class);
        @SuppressWarnings("unchecked") final ValueOperations<String,String> ops=mock(ValueOperations.class);
        final Map<String,String> values=new HashMap<>();
        final Listener listener=new Listener();
        Fixture(boolean enabled) {
            when(redis.opsForValue()).thenReturn(ops);
            when(ops.get(anyString())).thenAnswer(call->values.get(call.getArgument(0)));
            doAnswer(call->{values.put(call.getArgument(0),call.getArgument(1));return null;})
                    .when(ops).set(anyString(),anyString(),eq(30L),eq(TimeUnit.SECONDS));
            ReflectionTestUtils.setField(listener,"successMarkers",new ArticleIndexSuccessMarkers(redis,enabled,"test:",30));
        }
    }

    private ConsumerRecord<String,String> event(String event,String body) {
        return new ConsumerRecord<>("topic",0,10,"42","{\"schemaVersion\":1,\"eventId\":\""+event
                +"\",\"articleId\":\"42\",\"occurredAt\":1,\"payload\":{\"id\":42,\"content\":\""+body+"\"}}");
    }

    @Test
    void successfulMarkerIsOnlyWrittenAfterIndexAndDuplicateSkipsIndex() {
        Fixture f=new Fixture(true);
        f.listener.action=request->{
            assertTrue(f.values.isEmpty(),"No success marker may exist before index succeeds");
            assertFalse(request.source().utf8ToString().contains("schemaVersion"));
            assertTrue(request.source().utf8ToString().contains("body"));
        };
        f.listener.onMessage(event("e1","body"));
        assertEquals(1,f.values.size());assertEquals(1,f.listener.calls);
        f.listener.onMessage(event("e1","body"));
        assertEquals(1,f.listener.calls,"Duplicate with matching marker must bypass ES");
    }

    @Test
    void sameArticleNewEventAndTtlExpiryCanIndexAgainWhileConflictCannot() {
        Fixture f=new Fixture(true);
        f.listener.onMessage(event("e1","old"));f.listener.onMessage(event("e2","new"));
        assertEquals(2,f.listener.calls);assertEquals(2,f.values.size());
        assertThrows(NonRetryableArticleSyncException.class,()->f.listener.onMessage(event("e1","changed")));
        assertEquals(2,f.listener.calls);
        f.values.remove("test:app_info_article:e1");
        f.listener.onMessage(event("e1","old"));
        assertEquals(3,f.listener.calls,"Expired marker permits reprocessing, including old versions");
    }

    @Test
    void esFailureNeverWritesSuccessMarker() {
        Fixture f=new Fixture(true);f.listener.action=request->{throw new IOException("ES unavailable");};
        assertThrows(RuntimeException.class,()->f.listener.onMessage(event("e1","body")));
        assertTrue(f.values.isEmpty());
        verify(f.ops,never()).set(anyString(),anyString(),anyLong(),any(TimeUnit.class));
    }

    @Test
    void redisReadFailureStillIndexesAndWriteFailureDoesNotTurnSuccessIntoFailure() {
        Fixture f=new Fixture(true);
        when(f.ops.get(anyString())).thenThrow(new IllegalStateException("Redis get failed"));
        f.listener.onMessage(event("e1","body"));
        assertEquals(1,f.listener.calls);assertEquals(1,f.values.size());
        doThrow(new IllegalStateException("Redis set failed")).when(f.ops).set(anyString(),anyString(),eq(30L),eq(TimeUnit.SECONDS));
        assertDoesNotThrow(()->f.listener.onMessage(event("e2","body")));
        assertEquals(2,f.listener.calls);assertFalse(f.values.containsKey("test:app_info_article:e2"));
    }

    @Test
    void legacyAndDisabledDedupPreserveProcessingWithoutRedisCommands() {
        Fixture legacy=new Fixture(true);
        ConsumerRecord<String,String> raw=new ConsumerRecord<>("topic",0,1,null,"{\"id\":42,\"content\":\"legacy\"}");
        raw.headers().add("eventId",new byte[]{1,2,3});
        legacy.listener.onMessage(raw);legacy.listener.onMessage(raw);
        assertEquals(2,legacy.listener.calls);verifyNoInteractions(legacy.redis);
        Fixture disabled=new Fixture(false);
        disabled.listener.onMessage(event("e1","body"));disabled.listener.onMessage(event("e1","body"));
        assertEquals(2,disabled.listener.calls);verifyNoInteractions(disabled.redis);
    }
}
