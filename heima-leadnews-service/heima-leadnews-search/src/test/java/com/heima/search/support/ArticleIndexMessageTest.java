package com.heima.search.support;

import com.alibaba.fastjson.JSON;
import com.alibaba.fastjson.JSONObject;
import org.apache.kafka.clients.consumer.ConsumerRecord;
import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.util.Arrays;

import static org.junit.jupiter.api.Assertions.*;

class ArticleIndexMessageTest {
    private static final String ID = "2118965209396809730";

    private JSONObject envelope() {
        JSONObject p = new JSONObject(); p.put("id", Long.valueOf(ID)); p.put("title", "title"); p.put("content", "body");
        JSONObject e = new JSONObject(); e.put("schemaVersion", 1); e.put("eventId", "event-1");
        e.put("articleId", ID); e.put("occurredAt", 1794000000000L); e.put("payload", p); return e;
    }

    private ConsumerRecord<String, String> record(JSONObject payload) {
        return new ConsumerRecord<>("topic", 0, 0, ID, payload.toJSONString());
    }

    @Test
    void oldRawPayloadKeepsExactIdAndBypassesBusinessDedupEvenWithHeader() {
        ConsumerRecord<String, String> r = record(envelope().getJSONObject("payload"));
        r.headers().add("eventId", "legacy-header".getBytes(StandardCharsets.UTF_8));
        ArticleIndexMessage message = ArticleIndexMessage.parse(r);
        assertFalse(message.isVersioned()); assertNull(message.getEventId()); assertNull(message.getMarkerValue());
        assertEquals(Long.valueOf(ID), message.getArticle().getId()); assertEquals(r.value(), message.getIndexSource());
    }

    @Test
    void envelopeIndexesOnlyCanonicalPayloadAndFingerprintIsIndependentOfObjectOrder() {
        JSONObject e = envelope();
        ConsumerRecord<String, String> r = record(e); r.headers().add("eventId", "event-1".getBytes(StandardCharsets.UTF_8));
        ArticleIndexMessage message = ArticleIndexMessage.parse(r);
        assertTrue(message.isVersioned()); assertEquals("event-1", message.getEventId());
        JSONObject source = JSON.parseObject(message.getIndexSource());
        assertFalse(source.containsKey("schemaVersion")); assertFalse(source.containsKey("eventId"));
        assertEquals(Long.valueOf(ID), source.getLong("id"));
        e.put("payload", JSON.parseObject("{\"content\":\"body\",\"title\":\"title\",\"id\":" + ID + "}"));
        assertEquals(message.getMarkerValue(), ArticleIndexMessage.parse(record(e)).getMarkerValue());
        e.getJSONObject("payload").put("content", "changed");
        assertNotEquals(message.getMarkerValue(), ArticleIndexMessage.parse(record(e)).getMarkerValue());
    }

    @Test
    void malformedEnvelopeAndHeaderCannotUseLegacyFallback() {
        for (Object version : Arrays.asList(null, 2, "1", 1.5)) {
            JSONObject e=envelope(); e.put("schemaVersion", version);
            assertThrows(NonRetryableArticleSyncException.class, () -> ArticleIndexMessage.parse(record(e)));
        }
        for (String event : Arrays.asList("", " ", "bad\nid", "中文", new String(new char[129]).replace('\0','a'))) {
            JSONObject e=envelope();e.put("eventId",event);
            assertThrows(NonRetryableArticleSyncException.class, () -> ArticleIndexMessage.parse(record(e)));
        }
        for (Object id : Arrays.asList(null, Long.valueOf(ID), "01", "1.5", "9223372036854775808")) {
            JSONObject e=envelope();e.put("articleId",id);
            assertThrows(NonRetryableArticleSyncException.class, () -> ArticleIndexMessage.parse(record(e)));
        }
        for (Object time : Arrays.asList(null, 0, -1, "1000", 1.5)) {
            JSONObject e=envelope();e.put("occurredAt",time);
            assertThrows(NonRetryableArticleSyncException.class, () -> ArticleIndexMessage.parse(record(e)));
        }
        JSONObject mismatch=envelope();mismatch.getJSONObject("payload").put("id", 2);
        assertThrows(NonRetryableArticleSyncException.class, () -> ArticleIndexMessage.parse(record(mismatch)));
        JSONObject e=envelope(); e.put("payload", "wrong"); ConsumerRecord<String,String> wrongPayload=record(e);
        assertThrows(NonRetryableArticleSyncException.class, () -> ArticleIndexMessage.parse(wrongPayload));
        ConsumerRecord<String,String> wrongHeader=record(envelope()); wrongHeader.headers().add("eventId", "another".getBytes(StandardCharsets.UTF_8));
        assertThrows(NonRetryableArticleSyncException.class, () -> ArticleIndexMessage.parse(wrongHeader));
        ConsumerRecord<String,String> conflictingHeaders=record(envelope());
        conflictingHeaders.headers().add("eventId", "another".getBytes(StandardCharsets.UTF_8));
        conflictingHeaders.headers().add("eventId", "event-1".getBytes(StandardCharsets.UTF_8));
        assertThrows(NonRetryableArticleSyncException.class, () -> ArticleIndexMessage.parse(conflictingHeaders));
    }
}
