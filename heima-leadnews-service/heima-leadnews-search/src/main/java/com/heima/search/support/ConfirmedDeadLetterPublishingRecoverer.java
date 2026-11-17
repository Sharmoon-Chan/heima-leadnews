package com.heima.search.support;

import lombok.extern.slf4j.Slf4j;
import org.apache.kafka.clients.consumer.ConsumerRecord;
import org.apache.kafka.clients.producer.ProducerRecord;
import org.apache.kafka.clients.producer.RecordMetadata;
import org.apache.kafka.common.TopicPartition;
import org.springframework.kafka.KafkaException;
import org.springframework.kafka.core.KafkaOperations;
import org.springframework.kafka.listener.DeadLetterPublishingRecoverer;
import org.springframework.kafka.support.SendResult;
import org.springframework.util.Assert;

import java.util.concurrent.ExecutionException;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;
import java.util.function.BiFunction;

/**
 * Spring Kafka 2.6.6 has no fail-on-send-result option. Its publish() only logs
 * send failures. Override that boundary while retaining its original payload,
 * key and standard exception/source headers.
 */
@Slf4j
public class ConfirmedDeadLetterPublishingRecoverer extends DeadLetterPublishingRecoverer {
    private final long timeoutMs;

    public ConfirmedDeadLetterPublishingRecoverer(
            KafkaOperations<?, ?> template,
            BiFunction<ConsumerRecord<?, ?>, Exception, TopicPartition> resolver,
            long timeoutMs) {
        super(template, resolver);
        Assert.isTrue(timeoutMs > 0, "DLT acknowledgement timeout must be positive");
        this.timeoutMs = timeoutMs;
    }

    @Override
    public void accept(ConsumerRecord<?, ?> record, Exception exception) {
        try {
            super.accept(record, exception);
            log.info("article-sync outcome=dlt-confirmed eventId={} sourceTopic={} sourcePartition={} sourceOffset={} attempt={} exception={}",
                    SyncMessageMetadata.eventId(record), record.topic(), record.partition(), record.offset(),
                    SyncMessageMetadata.attempt(record), exception.getClass().getName());
        } catch (RuntimeException failure) {
            log.error("article-sync outcome=dlt-unconfirmed eventId={} sourceTopic={} sourcePartition={} sourceOffset={} attempt={} failure={}",
                    SyncMessageMetadata.eventId(record), record.topic(), record.partition(), record.offset(),
                    SyncMessageMetadata.attempt(record), failure.toString());
            throw failure;
        }
    }

    @Override
    protected void publish(ProducerRecord<Object, Object> record, KafkaOperations<Object, Object> template) {
        try {
            // send() can itself block up to producer max.block.ms. The additional
            // future wait is bounded here. A timed-out send may still succeed later:
            // leave the source unresolved, accepting possible duplicate DLT records.
            SendResult<Object, Object> result = template.send(record).get(timeoutMs, TimeUnit.MILLISECONDS);
            RecordMetadata metadata = result.getRecordMetadata();
            if (metadata == null || metadata.offset() < 0) {
                throw new KafkaException("DLT send returned no broker acknowledgement");
            }
            log.info("article-sync DLT broker-ack topic={} partition={} offset={}",
                    metadata.topic(), metadata.partition(), metadata.offset());
        } catch (InterruptedException failure) {
            Thread.currentThread().interrupt();
            throw new KafkaException("DLT acknowledgement interrupted", failure);
        } catch (ExecutionException failure) {
            throw new KafkaException("DLT send failed", failure.getCause());
        } catch (TimeoutException failure) {
            throw new KafkaException("DLT acknowledgement timed out after " + timeoutMs + "ms", failure);
        }
        // Synchronous Kafka send failures deliberately propagate to the container.
    }
}
