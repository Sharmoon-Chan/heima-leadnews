package com.heima.search.support;

import org.apache.kafka.clients.consumer.ConsumerRecord;
import org.apache.kafka.common.header.Header;
import org.springframework.kafka.support.KafkaHeaders;

import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;

/** Log identity only; this header is not a business deduplication protocol. */
public final class SyncMessageMetadata {
    private SyncMessageMetadata() {
    }

    public static String eventId(ConsumerRecord<?, ?> record) {
        Header event = record.headers().lastHeader("eventId");
        if (event != null && event.value() != null && event.value().length > 0) {
            String value = new String(event.value(), StandardCharsets.UTF_8)
                    .replace('\r', '_').replace('\n', '_');
            return value.length() <= 160 ? value : value.substring(0, 160);
        }
        return record.topic() + ":" + record.partition() + ":" + record.offset();
    }

    public static int attempt(ConsumerRecord<?, ?> record) {
        Header attempt = record.headers().lastHeader(KafkaHeaders.DELIVERY_ATTEMPT);
        return attempt != null && attempt.value() != null && attempt.value().length == 4
                ? ByteBuffer.wrap(attempt.value()).getInt() : 1;
    }
}
