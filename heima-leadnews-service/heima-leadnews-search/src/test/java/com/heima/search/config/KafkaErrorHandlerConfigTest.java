package com.heima.search.config;

import com.heima.search.support.NonRetryableArticleSyncException;
import org.apache.kafka.clients.consumer.Consumer;
import org.apache.kafka.clients.consumer.ConsumerRecord;
import org.apache.kafka.clients.producer.ProducerRecord;
import org.apache.kafka.clients.producer.RecordMetadata;
import org.apache.kafka.common.TopicPartition;
import org.junit.jupiter.api.Test;
import org.springframework.kafka.KafkaException;
import org.springframework.kafka.core.KafkaTemplate;
import org.springframework.kafka.listener.ListenerExecutionFailedException;
import org.springframework.kafka.listener.MessageListenerContainer;
import org.springframework.kafka.listener.SeekToCurrentErrorHandler;
import org.springframework.kafka.support.SendResult;
import org.springframework.kafka.support.TopicPartitionOffset;
import org.springframework.util.concurrent.SettableListenableFuture;

import java.util.Collections;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class KafkaErrorHandlerConfigTest {
    @SuppressWarnings("unchecked")
    private final KafkaTemplate<String, String> template = mock(KafkaTemplate.class);
    @SuppressWarnings("unchecked")
    private final Consumer<Object, Object> consumer = mock(Consumer.class);
    private final MessageListenerContainer container = mock(MessageListenerContainer.class);
    private final ConsumerRecord<String, String> source = new ConsumerRecord<>("source", 0, 9, "id", "{}");

    @SuppressWarnings("unchecked")
    private void acknowledge() {
        when(template.send(any(ProducerRecord.class))).thenAnswer(invocation -> {
            ProducerRecord<String, String> record = invocation.getArgument(0);
            SettableListenableFuture<SendResult<String, String>> future = new SettableListenableFuture<>();
            future.set(new SendResult<>(record, new RecordMetadata(new TopicPartition(record.topic(), record.partition()),
                    1L, 0L, 0L, null, 2, 2)));
            return future;
        });
    }

    @Test
    void retryableFailureGetsExactlyThreeRetriesBeforeDlt() {
        acknowledge();
        SeekToCurrentErrorHandler handler = new KafkaErrorHandlerConfig().kafkaErrorHandler(template, 100, "", -1);
        Exception failure = new ListenerExecutionFailedException("listener", new RuntimeException("ES unavailable"));
        for (int attempt = 1; attempt <= 3; attempt++) {
            assertEquals(attempt, handler.deliveryAttempt(new TopicPartitionOffset("source", 0, 9L)));
            assertThrows(KafkaException.class,
                    () -> handler.handle(failure, Collections.singletonList(source), consumer, container));
            verify(template, never()).send(any(ProducerRecord.class));
        }
        assertEquals(4, handler.deliveryAttempt(new TopicPartitionOffset("source", 0, 9L)));
        assertDoesNotThrow(() -> handler.handle(failure, Collections.singletonList(source), consumer, container));
        verify(template, times(1)).send(any(ProducerRecord.class));
        verify(consumer, times(3)).seek(new TopicPartition("source", 0), 9L);
    }

    @Test
    void wrappedValidationFailureGoesDirectlyToDlt() {
        acknowledge();
        SeekToCurrentErrorHandler handler = new KafkaErrorHandlerConfig().kafkaErrorHandler(template, 100, "", -1);
        assertDoesNotThrow(() -> handler.handle(new ListenerExecutionFailedException("listener",
                new NonRetryableArticleSyncException("missing-id")), Collections.singletonList(source), consumer, container));
        verify(template, times(1)).send(any(ProducerRecord.class));
        verify(consumer, never()).seek(any(TopicPartition.class), anyLong());
    }

    @Test
    void dltFailureSeeksBackWithoutCommittingSourceOffset() {
        when(template.send(any(ProducerRecord.class))).thenThrow(new IllegalArgumentException("invalid DLT partition"));
        SeekToCurrentErrorHandler handler = new KafkaErrorHandlerConfig().kafkaErrorHandler(template, 100, "bad.DLT", 99);
        assertThrows(KafkaException.class, () -> handler.handle(new ListenerExecutionFailedException("listener",
                new NonRetryableArticleSyncException("missing-id")), Collections.singletonList(source), consumer, container));
        verify(consumer).seek(new TopicPartition("source", 0), 9L);
        verifyNoMoreInteractions(consumer);
    }
}
