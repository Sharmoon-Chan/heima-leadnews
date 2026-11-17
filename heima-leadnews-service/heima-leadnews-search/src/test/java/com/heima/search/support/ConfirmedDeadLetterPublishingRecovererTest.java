package com.heima.search.support;

import org.apache.kafka.clients.consumer.ConsumerRecord;
import org.apache.kafka.clients.producer.ProducerRecord;
import org.apache.kafka.clients.producer.RecordMetadata;
import org.apache.kafka.common.TopicPartition;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.springframework.kafka.KafkaException;
import org.springframework.kafka.core.KafkaOperations;
import org.springframework.kafka.listener.DeadLetterPublishingRecoverer;
import org.springframework.kafka.support.KafkaHeaders;
import org.springframework.kafka.support.SendResult;
import org.springframework.util.concurrent.ListenableFuture;
import org.springframework.util.concurrent.SettableListenableFuture;

import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.TimeUnit;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class ConfirmedDeadLetterPublishingRecovererTest {
    @SuppressWarnings("unchecked")
    private final KafkaOperations<Object, Object> template = mock(KafkaOperations.class);
    private final ConsumerRecord<String, String> source = new ConsumerRecord<>("source", 2, 42L, "key", "{bad-json}");

    private ConfirmedDeadLetterPublishingRecoverer recoverer(long timeout) {
        return new ConfirmedDeadLetterPublishingRecoverer(template,
                (record, exception) -> new TopicPartition(record.topic() + ".DLT", record.partition()), timeout);
    }

    @Test
    @SuppressWarnings("unchecked")
    void brokerAcknowledgementPreservesPayloadSourceExceptionAndIdentityHeaders() {
        source.headers().add("eventId", "event-42".getBytes(StandardCharsets.UTF_8));
        source.headers().add(KafkaHeaders.DELIVERY_ATTEMPT, ByteBuffer.allocate(4).putInt(4).array());
        when(template.send(any(ProducerRecord.class))).thenAnswer(invocation -> {
            ProducerRecord<Object, Object> record = invocation.getArgument(0);
            SettableListenableFuture<SendResult<Object, Object>> result = new SettableListenableFuture<>();
            result.set(new SendResult<>(record, new RecordMetadata(new TopicPartition(record.topic(), record.partition()),
                    7L, 0L, 0L, null, 3, 10)));
            return result;
        });
        recoverer(100).accept(source, new NonRetryableArticleSyncException("invalid-json"));
        ArgumentCaptor<ProducerRecord> captured = ArgumentCaptor.forClass(ProducerRecord.class);
        verify(template).send(captured.capture());
        ProducerRecord record = captured.getValue();
        assertEquals("source.DLT", record.topic());
        assertEquals(Integer.valueOf(2), record.partition());
        assertEquals(source.value(), record.value());
        assertEquals(source.key(), record.key());
        assertEquals("source", new String(record.headers().lastHeader(KafkaHeaders.DLT_ORIGINAL_TOPIC).value(), StandardCharsets.UTF_8));
        assertEquals(42L, ByteBuffer.wrap(record.headers().lastHeader(KafkaHeaders.DLT_ORIGINAL_OFFSET).value()).getLong());
        assertEquals(2, ByteBuffer.wrap(record.headers().lastHeader(KafkaHeaders.DLT_ORIGINAL_PARTITION).value()).getInt());
        assertNotNull(record.headers().lastHeader(KafkaHeaders.DLT_EXCEPTION_FQCN));
        assertNotNull(record.headers().lastHeader(KafkaHeaders.DLT_EXCEPTION_STACKTRACE));
        assertEquals("event-42", new String(record.headers().lastHeader("eventId").value(), StandardCharsets.UTF_8));
        assertEquals(4, ByteBuffer.wrap(record.headers().lastHeader(KafkaHeaders.DELIVERY_ATTEMPT).value()).getInt());
    }

    @Test
    @SuppressWarnings("unchecked")
    void asynchronousFailurePropagatesInsteadOfReportingRecovery() {
        SettableListenableFuture<SendResult<Object, Object>> future = new SettableListenableFuture<>();
        IllegalStateException failure = new IllegalStateException("broker unavailable");
        future.setException(failure);
        when(template.send(any(ProducerRecord.class))).thenReturn(future);
        KafkaException thrown = assertThrows(KafkaException.class, () -> recoverer(100).accept(source, new RuntimeException("ES")));
        assertSame(failure, thrown.getCause());
    }

    @Test
    @SuppressWarnings("unchecked")
    void synchronousFailurePropagates() {
        IllegalArgumentException failure = new IllegalArgumentException("partition does not exist");
        when(template.send(any(ProducerRecord.class))).thenThrow(failure);
        assertSame(failure, assertThrows(IllegalArgumentException.class,
                () -> recoverer(100).accept(source, new RuntimeException("ES"))));
    }

    @Test
    @SuppressWarnings("unchecked")
    void unresolvedFutureTimesOutAndIsNotCancelledAsIfItHadNotBeenSent() {
        SettableListenableFuture<SendResult<Object, Object>> future = new SettableListenableFuture<>();
        when(template.send(any(ProducerRecord.class))).thenReturn(future);
        KafkaException thrown = assertThrows(KafkaException.class,
                () -> recoverer(10).accept(source, new RuntimeException("ES")));
        assertTrue(thrown.getCause() instanceof java.util.concurrent.TimeoutException);
        assertFalse(future.isCancelled());
    }

    @Test
    @SuppressWarnings("unchecked")
    void interruptionRestoresInterruptFlag() throws Exception {
        ListenableFuture<SendResult<Object, Object>> future = mock(ListenableFuture.class);
        when(template.send(any(ProducerRecord.class))).thenReturn(future);
        when(future.get(anyLong(), eq(TimeUnit.MILLISECONDS))).thenThrow(new InterruptedException("stop"));
        try {
            assertThrows(KafkaException.class, () -> recoverer(100).accept(source, new RuntimeException("ES")));
            assertTrue(Thread.currentThread().isInterrupted());
        } finally {
            Thread.interrupted();
        }
    }

    @Test
    @SuppressWarnings("unchecked")
    void installedNativeRecovererDemonstratesTheOriginalSwallowingBehavior() {
        SettableListenableFuture<SendResult<Object, Object>> future = new SettableListenableFuture<>();
        future.setException(new IllegalStateException("broker failed"));
        when(template.send(any(ProducerRecord.class))).thenReturn(future);
        DeadLetterPublishingRecoverer nativeRecoverer = new DeadLetterPublishingRecoverer(template);
        assertDoesNotThrow(() -> nativeRecoverer.accept(source, new RuntimeException("ES")));
        when(template.send(any(ProducerRecord.class))).thenThrow(new IllegalStateException("sync failed"));
        assertDoesNotThrow(() -> nativeRecoverer.accept(source, new RuntimeException("ES")));
    }
}
