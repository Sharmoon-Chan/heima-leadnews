package com.heima.search.listener;

import com.heima.search.support.NonRetryableArticleSyncException;
import org.apache.kafka.clients.consumer.ConsumerRecord;
import org.elasticsearch.ElasticsearchStatusException;
import org.elasticsearch.rest.RestStatus;
import org.junit.jupiter.api.Test;

import java.io.IOException;

import static org.junit.jupiter.api.Assertions.*;

class SyncArticleListenerTest {
    @Test
    void blankMalformedAndMissingIdAreNeverSilentlyAccepted() {
        SyncArticleListener listener = new SyncArticleListener();
        String[] badMessages = {null, "", " \t\n", "{not-json", "[]", "null", "{}", "{\"title\":\"missing\"}",
                "{\"id\":0}", "{\"id\":-1}", "{\"id\":\"abc\"}"};
        for (String payload : badMessages) {
            assertThrows(NonRetryableArticleSyncException.class,
                    () -> listener.onMessage(new ConsumerRecord<>("source", 0, 5, "key", payload)),
                    "payload=" + payload);
        }
    }

    @Test
    void existingPayloadKeepsTheFullLongArticleId() {
        assertEquals(Long.valueOf(2118965209396809730L), SyncArticleListener.parseArticle(
                "{\"id\":2118965209396809730,\"title\":\"test\"}").getId());
    }

    @Test
    void permanentPayloadRejectionIsNonRetryableButOperationalErrorsRemainRetryable() {
        Exception mapping = new ElasticsearchStatusException("mapping rejected", RestStatus.BAD_REQUEST);
        assertTrue(SyncArticleListener.classifyIndexFailure(1L, mapping) instanceof NonRetryableArticleSyncException);
        Exception[] temporary = {
                new ElasticsearchStatusException("busy", RestStatus.TOO_MANY_REQUESTS),
                new ElasticsearchStatusException("unavailable", RestStatus.SERVICE_UNAVAILABLE),
                new ElasticsearchStatusException("credentials need repair", RestStatus.FORBIDDEN),
                new IOException("connection reset")};
        for (Exception failure : temporary) {
            RuntimeException classified = SyncArticleListener.classifyIndexFailure(1L, failure);
            assertFalse(classified instanceof NonRetryableArticleSyncException);
            assertSame(failure, classified.getCause());
        }
    }
}
