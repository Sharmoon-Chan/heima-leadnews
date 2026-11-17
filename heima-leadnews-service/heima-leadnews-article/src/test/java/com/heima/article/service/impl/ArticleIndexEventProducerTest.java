package com.heima.article.service.impl;

import com.alibaba.fastjson.JSON;
import com.alibaba.fastjson.JSONObject;
import com.heima.model.article.pojos.ApArticle;
import com.heima.model.search.vos.ArticleIndexEvent;
import com.heima.model.search.vos.SearchArticleVo;
import org.apache.kafka.clients.producer.ProducerRecord;
import org.apache.kafka.clients.producer.RecordMetadata;
import org.apache.kafka.common.TopicPartition;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.springframework.kafka.core.KafkaTemplate;
import org.springframework.kafka.support.SendResult;
import org.springframework.test.util.ReflectionTestUtils;
import org.springframework.util.concurrent.SettableListenableFuture;

import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.*;

class ArticleIndexEventProducerTest {
    private static final Long ID = 2118965209396809730L;
    private static final String TOPIC = "p22-producer-unit";

    @SuppressWarnings("unchecked")
    private final KafkaTemplate<String, String> template = mock(KafkaTemplate.class);

    private ArticleFreemarkerServiceImpl service() {
        ArticleFreemarkerServiceImpl service = new ArticleFreemarkerServiceImpl();
        ReflectionTestUtils.setField(service, "kafkaTemplate", template);
        ReflectionTestUtils.setField(service, "articleIndexTopic", TOPIC);
        return service;
    }

    private ApArticle article() {
        ApArticle article = new ApArticle();
        article.setId(ID);
        article.setTitle("P2.2 event identity");
        return article;
    }

    private void invoke(ArticleFreemarkerServiceImpl service, ApArticle article, String content) {
        ReflectionTestUtils.invokeMethod(service, "createArticleESIndex", article, content, "http://example.test/article.html");
    }

    @SuppressWarnings({"unchecked", "rawtypes"})
    private List<ProducerRecord<String, String>> records(int count) {
        ArgumentCaptor<ProducerRecord> captor = ArgumentCaptor.forClass(ProducerRecord.class);
        verify(template, times(count)).send(captor.capture());
        return (List) captor.getAllValues();
    }

    @Test
    @SuppressWarnings("unchecked")
    void envelopeKeyAndHeaderShareExactIdentityAndSuccessfulCallbackKeepsOriginalBytes() {
        SettableListenableFuture<SendResult<String, String>> result = new SettableListenableFuture<>();
        when(template.send(any(ProducerRecord.class))).thenReturn(result);
        ArticleFreemarkerServiceImpl service = service();
        ApArticle article = article();
        long before = System.currentTimeMillis();
        invoke(service, article, "[{\"type\":\"text\",\"value\":\"中文正文\"}]");
        long after = System.currentTimeMillis();
        ProducerRecord<String, String> record = records(1).get(0);
        String bytesBeforeCallback = record.value();
        JSONObject envelope = JSON.parseObject(record.value());
        String eventId = envelope.getString("eventId");
        assertNotNull(UUID.fromString(eventId));
        assertEquals(TOPIC, record.topic());
        assertEquals(ID.toString(), record.key());
        assertEquals(ID.toString(), envelope.get("articleId"));
        assertEquals(1, envelope.getIntValue("schemaVersion"));
        assertTrue(envelope.getLongValue("occurredAt") >= before && envelope.getLongValue("occurredAt") <= after);
        assertEquals(eventId, new String(record.headers().lastHeader("eventId").value(), StandardCharsets.UTF_8));
        assertEquals(ID, envelope.getJSONObject("payload").getLong("id"));
        assertEquals("P2.2 event identity", envelope.getJSONObject("payload").getString("title"));
        assertTrue(envelope.getJSONObject("payload").getString("content").contains("中文正文"));
        assertEquals("http://example.test/article.html", envelope.getJSONObject("payload").getString("staticUrl"));

        article.setId(1L); // async caller mutation cannot change the already serialized record
        result.set(new SendResult<>(record, new RecordMetadata(new TopicPartition(TOPIC, 0), 5, 0, 0, null, 0, 0)));
        assertEquals(bytesBeforeCallback, record.value());
        assertEquals(ID.toString(), record.key());
        assertEquals(eventId, new String(record.headers().lastHeader("eventId").value(), StandardCharsets.UTF_8));
        verifyNoMoreInteractions(template);
    }

    @Test
    @SuppressWarnings("unchecked")
    void anotherLogicalInvocationForSameArticleHasANewEventIdButSamePartitionKey() {
        when(template.send(any(ProducerRecord.class))).thenReturn(new SettableListenableFuture<SendResult<String, String>>());
        ArticleFreemarkerServiceImpl service = service();
        invoke(service, article(), "first content");
        invoke(service, article(), "next content");
        List<ProducerRecord<String, String>> records = records(2);
        assertEquals(records.get(0).key(), records.get(1).key());
        JSONObject first = JSON.parseObject(records.get(0).value());
        JSONObject next = JSON.parseObject(records.get(1).value());
        assertNotEquals(first.getString("eventId"), next.getString("eventId"));
        assertEquals(first.getString("articleId"), next.getString("articleId"));
        assertEquals("next content", next.getJSONObject("payload").getString("content"));
    }

    @Test
    @SuppressWarnings("unchecked")
    void asynchronousFailureDoesNotCreateAnotherEventOrSilentlyResend() {
        SettableListenableFuture<SendResult<String, String>> result = new SettableListenableFuture<>();
        when(template.send(any(ProducerRecord.class))).thenReturn(result);
        invoke(service(), article(), "body");
        ProducerRecord<String, String> record = records(1).get(0);
        String original = record.value();
        assertDoesNotThrow(() -> result.setException(new IllegalStateException("bounded broker failure")));
        assertEquals(original, record.value());
        verifyNoMoreInteractions(template);
    }

    @Test
    @SuppressWarnings("unchecked")
    void synchronousFailureKeepsTheOriginalExceptionAndSingleRecordIdentity() {
        IllegalStateException failed = new IllegalStateException("producer stopped");
        when(template.send(any(ProducerRecord.class))).thenThrow(failed);
        assertSame(failed, assertThrows(IllegalStateException.class, () -> invoke(service(), article(), "body")));
        ProducerRecord<String, String> record = records(1).get(0);
        assertEquals(JSON.parseObject(record.value()).getString("eventId"),
                new String(record.headers().lastHeader("eventId").value(), StandardCharsets.UTF_8));
        verifyNoMoreInteractions(template);
    }

    @Test
    void envelopeFactoryRequiresPositiveArticleIdentity() {
        assertThrows(IllegalArgumentException.class, () -> ArticleIndexEvent.create(null));
        SearchArticleVo payload = new SearchArticleVo();
        assertThrows(IllegalArgumentException.class, () -> ArticleIndexEvent.create(payload));
        payload.setId(0L);
        assertThrows(IllegalArgumentException.class, () -> ArticleIndexEvent.create(payload));
    }
}
