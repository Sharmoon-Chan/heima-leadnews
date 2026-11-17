package com.heima.model.search.vos;

import lombok.Data;

import java.util.UUID;

/**
 * Identity of one logical indexing invocation, not an article content version.
 * Kafka retries and DLT replay retain the serialized event and its eventId.
 * A repeated upstream save invocation creates another event: no outbox or request deduplication is implied.
 */
@Data
public class ArticleIndexEvent {
    public static final int CURRENT_SCHEMA_VERSION = 1;

    private Integer schemaVersion;
    private String eventId;
    private String articleId;
    private Long occurredAt;
    private SearchArticleVo payload;

    public static ArticleIndexEvent create(SearchArticleVo payload) {
        if (payload == null || payload.getId() == null || payload.getId() <= 0) {
            throw new IllegalArgumentException("Article index event requires a positive articleId");
        }
        ArticleIndexEvent event = new ArticleIndexEvent();
        event.setSchemaVersion(CURRENT_SCHEMA_VERSION);
        event.setEventId(UUID.randomUUID().toString());
        event.setArticleId(payload.getId().toString());
        event.setOccurredAt(System.currentTimeMillis());
        event.setPayload(payload);
        return event;
    }
}
