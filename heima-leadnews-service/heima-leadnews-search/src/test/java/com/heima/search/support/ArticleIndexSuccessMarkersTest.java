package com.heima.search.support;

import org.apache.kafka.clients.consumer.ConsumerRecord;
import org.junit.jupiter.api.Test;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.data.redis.core.ValueOperations;
import java.util.concurrent.TimeUnit;
import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;
import static org.mockito.ArgumentMatchers.*;

class ArticleIndexSuccessMarkersTest {
    private ArticleIndexMessage event(String id) {
        return ArticleIndexMessage.parse(new ConsumerRecord<>("t",0,0,null,
                "{\"schemaVersion\":1,\"eventId\":\""+id+"\",\"articleId\":\"42\",\"occurredAt\":1,\"payload\":{\"id\":42,\"content\":\"body\"}}"));
    }

    @Test
    @SuppressWarnings("unchecked")
    void markerIncludesIndexAndEventAndUsesOneAtomicSetWithExpiry() {
        StringRedisTemplate redis=mock(StringRedisTemplate.class); ValueOperations<String,String> ops=mock(ValueOperations.class);
        when(redis.opsForValue()).thenReturn(ops);
        ArticleIndexSuccessMarkers markers=new ArticleIndexSuccessMarkers(redis,true,"test:",86400);
        ArticleIndexMessage first=event("e1"),next=event("e2");
        assertEquals("test:idx:e1",markers.key("idx",first));assertNotEquals(markers.key("idx",first),markers.key("other",first));
        assertNotEquals(markers.key("idx",first),markers.key("idx",next));
        assertEquals(ArticleIndexSuccessMarkers.State.MISS,markers.lookup("idx",first).getState());
        assertTrue(markers.markSuccessful("idx",first).isSuccessful());
        verify(ops).set("test:idx:e1",first.getMarkerValue(),86400,TimeUnit.SECONDS);
        when(ops.get("test:idx:e1")).thenReturn(first.getMarkerValue());
        assertEquals(ArticleIndexSuccessMarkers.State.HIT,markers.lookup("idx",first).getState());
        when(ops.get("test:idx:e1")).thenReturn("different");
        assertThrows(NonRetryableArticleSyncException.class,()->markers.lookup("idx",first));
    }

    @Test
    @SuppressWarnings("unchecked")
    void redisFailuresAreExplicitAndLegacyDisabledAvoidsAllRedisCalls() {
        StringRedisTemplate redis=mock(StringRedisTemplate.class);ValueOperations<String,String> ops=mock(ValueOperations.class);
        when(redis.opsForValue()).thenReturn(ops);
        ArticleIndexSuccessMarkers markers=new ArticleIndexSuccessMarkers(redis,true,"test:",3);
        when(ops.get(anyString())).thenThrow(new IllegalStateException("read unavailable"));
        assertEquals(ArticleIndexSuccessMarkers.State.UNAVAILABLE,markers.lookup("idx",event("e1")).getState());
        doThrow(new IllegalStateException("write unavailable")).when(ops).set(anyString(),anyString(),eq(3L),eq(TimeUnit.SECONDS));
        assertFalse(markers.markSuccessful("idx",event("e1")).isSuccessful());
        reset(redis,ops);
        ArticleIndexMessage legacy=ArticleIndexMessage.parse(new ConsumerRecord<>("t",0,0,null,"{\"id\":42}"));
        assertEquals(ArticleIndexSuccessMarkers.State.DISABLED,markers.lookup("idx",legacy).getState());
        assertFalse(markers.markSuccessful("idx",legacy).isSuccessful());
        ArticleIndexSuccessMarkers disabled=new ArticleIndexSuccessMarkers(redis,false,"test:",3);
        assertEquals(ArticleIndexSuccessMarkers.State.DISABLED,disabled.lookup("idx",event("e1")).getState());
        verifyNoInteractions(redis);
        assertThrows(IllegalArgumentException.class,()->new ArticleIndexSuccessMarkers(redis,true,"",3));
        assertThrows(IllegalArgumentException.class,()->new ArticleIndexSuccessMarkers(redis,true,"test:",0));
    }
}
