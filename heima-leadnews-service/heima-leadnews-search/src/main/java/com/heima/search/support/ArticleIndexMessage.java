package com.heima.search.support;

import com.alibaba.fastjson.JSON;
import com.alibaba.fastjson.JSONObject;
import com.heima.model.search.vos.SearchArticleVo;
import org.apache.kafka.clients.consumer.ConsumerRecord;
import org.apache.kafka.common.header.Header;

import java.math.BigInteger;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.TreeMap;

/** Versioned event parsing; raw legacy articles deliberately have no business dedup identity. */
public final class ArticleIndexMessage {
    private final SearchArticleVo article;
    private final String eventId;
    private final String indexSource;
    private final String markerValue;

    private ArticleIndexMessage(SearchArticleVo article, String eventId, String indexSource, String markerValue) {
        this.article = article;
        this.eventId = eventId;
        this.indexSource = indexSource;
        this.markerValue = markerValue;
    }

    public SearchArticleVo getArticle() { return article; }
    public String getEventId() { return eventId; }
    public String getIndexSource() { return indexSource; }
    public String getMarkerValue() { return markerValue; }
    public boolean isVersioned() { return eventId != null; }

    public static ArticleIndexMessage parse(ConsumerRecord<String, String> record) {
        String message = record.value();
        if (message == null || message.trim().isEmpty()) throw invalid("blank-message");
        JSONObject root;
        try {
            Object value = JSON.parse(message);
            if (!(value instanceof JSONObject)) throw invalid("invalid-json-or-article-schema");
            root = (JSONObject) value;
        } catch (NonRetryableArticleSyncException e) {
            throw e;
        } catch (RuntimeException e) {
            throw new NonRetryableArticleSyncException("invalid-json-or-article-schema", e);
        }
        boolean envelope = root.containsKey("schemaVersion") || root.containsKey("eventId")
                || root.containsKey("articleId") || root.containsKey("occurredAt") || root.containsKey("payload");
        if (!envelope) {
            return new ArticleIndexMessage(article(root), null, message, null);
        }
        if (!BigInteger.ONE.equals(integer(root.get("schemaVersion")))) throw invalid("unsupported-event-schema-version");
        Object id = root.get("eventId");
        if (!(id instanceof String) || !((String) id).matches("[A-Za-z0-9._:-]{1,128}")) throw invalid("invalid-event-id");
        String eventId = (String) id;
        Object articleId = root.get("articleId");
        if (!(articleId instanceof String) || !((String) articleId).matches("[1-9][0-9]{0,18}")) throw invalid("invalid-event-article-id");
        long exactId = positiveLong(articleId);
        BigInteger occurredAt = integer(root.get("occurredAt"));
        if (occurredAt == null || occurredAt.signum() <= 0 || occurredAt.bitLength() > 63) throw invalid("invalid-event-occurred-at");
        if (!(root.get("payload") instanceof JSONObject)) throw invalid("missing-event-payload");
        JSONObject payload = root.getJSONObject("payload");
        SearchArticleVo article = article(payload);
        if (article.getId().longValue() != exactId) throw invalid("event-payload-article-id-mismatch");
        byte[] expectedHeader = eventId.getBytes(StandardCharsets.UTF_8);
        for (Header header : record.headers().headers("eventId")) {
            if (header.value() == null || !MessageDigest.isEqual(expectedHeader, header.value()))
                throw invalid("event-header-id-mismatch");
        }
        String source = JSON.toJSONString(canonical(payload));
        return new ArticleIndexMessage(article, eventId, source, "v1:" + exactId + ":" + sha256(source));
    }

    private static SearchArticleVo article(JSONObject payload) {
        if (!payload.containsKey("id") || payload.get("id") == null) throw invalid("missing-article-id");
        long id = positiveLong(payload.get("id"));
        try {
            SearchArticleVo article = payload.toJavaObject(SearchArticleVo.class);
            article.setId(id);
            return article;
        } catch (RuntimeException e) {
            throw new NonRetryableArticleSyncException("invalid-article-schema", e);
        }
    }

    private static long positiveLong(Object value) {
        BigInteger number;
        if (value instanceof String && ((String) value).matches("[1-9][0-9]{0,18}")) number = new BigInteger((String) value);
        else number = integer(value);
        if (number == null || number.signum() <= 0 || number.bitLength() > 63) throw invalid("invalid-article-id");
        return number.longValue();
    }

    private static BigInteger integer(Object value) {
        if (value instanceof Byte || value instanceof Short || value instanceof Integer || value instanceof Long)
            return BigInteger.valueOf(((Number) value).longValue());
        if (value instanceof BigInteger) return (BigInteger) value;
        return null;
    }

    private static Object canonical(Object value) {
        if (value instanceof Map) {
            Map<String, Object> sorted = new TreeMap<>();
            ((Map<?, ?>) value).forEach((k, v) -> sorted.put(String.valueOf(k), canonical(v)));
            return sorted;
        }
        if (value instanceof List) {
            List<Object> list = new ArrayList<>();
            for (Object item : (List<?>) value) list.add(canonical(item));
            return list;
        }
        return value;
    }

    private static String sha256(String value) {
        try {
            byte[] bytes = MessageDigest.getInstance("SHA-256").digest(value.getBytes(StandardCharsets.UTF_8));
            StringBuilder result = new StringBuilder(64);
            for (byte b : bytes) result.append(String.format("%02x", b & 255));
            return result.toString();
        } catch (java.security.NoSuchAlgorithmException e) {
            throw new IllegalStateException("SHA-256 unavailable", e);
        }
    }

    private static NonRetryableArticleSyncException invalid(String reason) {
        return new NonRetryableArticleSyncException(reason);
    }
}
