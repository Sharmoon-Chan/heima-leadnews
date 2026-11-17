package com.heima.search.listener;

import com.heima.model.search.vos.SearchArticleVo;
import com.heima.search.support.ArticleIndexMessage;
import com.heima.search.support.ArticleIndexSuccessMarkers;
import com.heima.search.support.NonRetryableArticleSyncException;
import com.heima.search.support.SyncMessageMetadata;
import lombok.extern.slf4j.Slf4j;
import org.apache.kafka.clients.consumer.ConsumerRecord;
import org.elasticsearch.ElasticsearchStatusException;
import org.elasticsearch.action.index.IndexRequest;
import org.elasticsearch.action.index.IndexResponse;
import org.elasticsearch.client.RequestOptions;
import org.elasticsearch.client.RestHighLevelClient;
import org.elasticsearch.common.xcontent.XContentType;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.kafka.annotation.KafkaListener;
import org.springframework.stereotype.Component;

import java.io.IOException;
import java.nio.charset.StandardCharsets;

@Component
@Slf4j
public class SyncArticleListener {
    @Autowired
    private RestHighLevelClient restHighLevelClient;

    @Autowired
    private ArticleIndexSuccessMarkers successMarkers;

    @Value("${leadnews.search.sync.index:app_info_article}")
    private String indexName = "app_info_article";

    // Resolve the existing consumer group explicitly; an empty resolved annotation
    // value overrides the factory group in this Spring Kafka version.
    @KafkaListener(topics = "${leadnews.search.sync.topic:article.es.sync.topic}",
            autoStartup = "${leadnews.search.sync.auto-startup:true}",
            groupId = "${leadnews.search.sync.group-id:${spring.kafka.consumer.group-id:leadnews-search}}")
    public void onMessage(ConsumerRecord<String, String> record) {
        String message = record.value();
        String eventId = SyncMessageMetadata.eventId(record);
        int attempt = SyncMessageMetadata.attempt(record);
        log.info("article-sync outcome=attempt eventId={} sourceTopic={} sourcePartition={} sourceOffset={} attempt={} messageUtf8Bytes={}",
                eventId, record.topic(), record.partition(), record.offset(), attempt, utf8Bytes(message));

        ArticleIndexMessage event;
        try {
            event = ArticleIndexMessage.parse(record);
        } catch (NonRetryableArticleSyncException failure) {
            log.warn("article-sync outcome=nonretryable eventId={} sourceTopic={} sourcePartition={} sourceOffset={} attempt={} reason={}",
                    eventId, record.topic(), record.partition(), record.offset(), attempt, failure.getMessage());
            throw failure;
        }
        SearchArticleVo article = event.getArticle();
        if (event.isVersioned()) eventId = event.getEventId();
        if (log.isDebugEnabled()) {
            log.debug("SyncArticleListener, payload={}", message);
        }

        ArticleIndexSuccessMarkers.Lookup lookup = successMarkers.lookup(indexName, event);
        log.info("article-sync outcome=dedup-lookup eventId={} articleId={} sourceTopic={} sourcePartition={} sourceOffset={} state={} elapsedMicros={}",
                eventId, article.getId(), record.topic(), record.partition(), record.offset(),
                lookup.getState(), lookup.getElapsedMicros());
        if (lookup.getState() == ArticleIndexSuccessMarkers.State.HIT) {
            log.info("article-sync outcome=dedup-hit eventId={} articleId={} sourceTopic={} sourcePartition={} sourceOffset={} attempt={}",
                    eventId, article.getId(), record.topic(), record.partition(), record.offset(), attempt);
            return;
        }
        if (lookup.getState() == ArticleIndexSuccessMarkers.State.UNAVAILABLE) {
            log.warn("article-sync outcome=redis-read-failed eventId={} articleId={} sourceTopic={} sourcePartition={} sourceOffset={} elapsedMicros={} failureType={}; continuing ES path",
                    eventId, article.getId(), record.topic(), record.partition(), record.offset(),
                    lookup.getElapsedMicros(), lookup.getFailureType());
        }

        // A successful marker saves repeated ES calls, but the lookup/index/set steps
        // are not atomic. Concurrent arrivals and a crash before SET may still re-index.
        IndexRequest request = new IndexRequest(indexName).id(article.getId().toString())
                .source(event.getIndexSource(), XContentType.JSON);
        IndexResponse response;
        long esStart = System.nanoTime();
        try {
            response = index(request);
        } catch (IOException | RuntimeException failure) {
            RuntimeException classified = classifyIndexFailure(article.getId(), failure);
            log.warn("article-sync outcome={} eventId={} sourceTopic={} sourcePartition={} sourceOffset={} attempt={} articleId={} failure={}",
                    classified instanceof NonRetryableArticleSyncException ? "nonretryable" : "retryable",
                    eventId, record.topic(), record.partition(), record.offset(), attempt, article.getId(), failure.toString());
            throw classified;
        }
        long esMicros = (System.nanoTime() - esStart) / 1000L;
        log.info("SyncArticleListener, indexed articleId={}, index={}, _id={}, result={}, version={}, seqNo={}, primaryTerm={}, shards={}/{}/{}, eventId={}, sourceTopic={}, sourcePartition={}, sourceOffset={}, attempt={}",
                article.getId(), response.getIndex(), response.getId(), response.getResult(), response.getVersion(),
                response.getSeqNo(), response.getPrimaryTerm(), response.getShardInfo().getSuccessful(),
                response.getShardInfo().getTotal(), response.getShardInfo().getFailed(), eventId,
                record.topic(), record.partition(), record.offset(), attempt);
        log.info("article-sync outcome={} eventId={} articleId={} sourceTopic={} sourcePartition={} sourceOffset={} elapsedMicros={}",
                event.isVersioned() ? "event-indexed" : "legacy-indexed", eventId, article.getId(), record.topic(),
                record.partition(), record.offset(), esMicros);

        // Deliberately outside the ES failure catch. A marker write error must not
        // turn an acknowledged ES write into an indexing failure or DLT event.
        if (event.isVersioned() && lookup.getState() != ArticleIndexSuccessMarkers.State.DISABLED) {
            ArticleIndexSuccessMarkers.Write write = successMarkers.markSuccessful(indexName, event);
            if (write.isSuccessful()) {
                log.info("article-sync outcome=marker-written eventId={} articleId={} sourceTopic={} sourcePartition={} sourceOffset={} elapsedMicros={}",
                        eventId, article.getId(), record.topic(), record.partition(), record.offset(), write.getElapsedMicros());
            } else {
                log.warn("article-sync outcome=redis-write-failed eventId={} articleId={} sourceTopic={} sourcePartition={} sourceOffset={} elapsedMicros={} failureType={}; ES success retained",
                        eventId, article.getId(), record.topic(), record.partition(), record.offset(),
                        write.getElapsedMicros(), write.getFailureType());
            }
        }
    }

    static SearchArticleVo parseArticle(String message) {
        return ArticleIndexMessage.parse(new ConsumerRecord<>("legacy-parser", 0, 0, null, message)).getArticle();
    }

    IndexResponse index(IndexRequest request) throws IOException {
        return restHighLevelClient.index(request, RequestOptions.DEFAULT);
    }

    static RuntimeException classifyIndexFailure(Long articleId, Exception failure) {
        if (failure instanceof ElasticsearchStatusException) {
            int status = ((ElasticsearchStatusException) failure).status().getStatus();
            // Payload/mapping rejection cannot improve by repeating the same bytes.
            // 429, 503, connection/IO failures and other operational errors stay retryable.
            if (status == 400 || status == 422) {
                return new NonRetryableArticleSyncException("es-permanent-status=" + status + ", articleId=" + articleId, failure);
            }
        }
        return new RuntimeException("Article index sync failed, articleId=" + articleId, failure);
    }

    private static int utf8Bytes(String value) {
        return value == null ? 0 : value.getBytes(StandardCharsets.UTF_8).length;
    }
}
