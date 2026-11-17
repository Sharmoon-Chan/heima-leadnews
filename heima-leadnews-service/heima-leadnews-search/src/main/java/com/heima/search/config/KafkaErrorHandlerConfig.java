package com.heima.search.config;

import com.heima.search.support.ConfirmedDeadLetterPublishingRecoverer;
import com.heima.search.support.NonRetryableArticleSyncException;
import org.apache.kafka.common.TopicPartition;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.autoconfigure.kafka.ConcurrentKafkaListenerContainerFactoryConfigurer;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.kafka.config.ConcurrentKafkaListenerContainerFactory;
import org.springframework.kafka.core.ConsumerFactory;
import org.springframework.kafka.core.KafkaTemplate;
import org.springframework.kafka.listener.SeekToCurrentErrorHandler;
import org.springframework.util.backoff.FixedBackOff;

/**
 * Kafka 消费失败处理：先重试，重试耗尽后投递死信。
 * 死信 topic 默认是原 topic 加 ".DLT" 后缀。
 */
@Configuration
public class KafkaErrorHandlerConfig {

    /**
     * 重试 + 死信处理器。
     * 注意：SeekToCurrentErrorHandler 是「容器级」错误处理器，只能挂到监听容器上；
     * 而 @KafkaListener 的 errorHandler 属性要求的是「监听方法级」的 KafkaListenerErrorHandler，
     * 两者类型不兼容（MQ-001 的启动失败就来自这里），所以改由下面的容器工厂挂载。
     */
    @Bean("kafkaErrorHandler")
    public SeekToCurrentErrorHandler kafkaErrorHandler(
            KafkaTemplate<String, String> kafkaTemplate,
            @Value("${leadnews.search.sync.dlt-timeout-ms:10000}") long timeoutMs,
            @Value("${leadnews.search.sync.dlt-topic:}") String dltTopic,
            @Value("${leadnews.search.sync.dlt-partition:-1}") int dltPartition) {
        if (dltPartition < -1) {
            throw new IllegalArgumentException("DLT partition must be -1 (source partition) or nonnegative");
        }
        ConfirmedDeadLetterPublishingRecoverer recoverer = new ConfirmedDeadLetterPublishingRecoverer(
                kafkaTemplate,
                (record, exception) -> new TopicPartition(
                        dltTopic.isEmpty() ? record.topic() + ".DLT" : dltTopic,
                        dltPartition < 0 ? record.partition() : dltPartition),
                timeoutMs);
        // 2.6.6 sends this exact partition; it has no verify-partition fallback.
        // Three retries AFTER the initial attempt, then confirmed DLT recovery.
        SeekToCurrentErrorHandler handler = new SeekToCurrentErrorHandler(recoverer, new FixedBackOff(1000L, 3));
        handler.addNotRetryableExceptions(NonRetryableArticleSyncException.class);
        // A failed DLT publication stays unresolved; do not start a new retry cycle.
        handler.setResetStateOnRecoveryFailure(false);
        return handler;
    }

    /**
     * 监听容器工厂：把上面的容器级错误处理器真正挂到消费容器上。
     * 用 Boot 的 configurer 构建，因此 spring.kafka.*（反序列化、group-id、ack、并发等）
     * 全部沿用既有设置，不会因为手工 new 工厂而丢失。
     * Bean 名与 Boot 默认工厂同名，Boot 的自动配置会自动退让。
     */
    @Bean("kafkaListenerContainerFactory")
    public ConcurrentKafkaListenerContainerFactory<Object, Object> kafkaListenerContainerFactory(
            ConcurrentKafkaListenerContainerFactoryConfigurer configurer,
            ConsumerFactory<Object, Object> consumerFactory,
            SeekToCurrentErrorHandler kafkaErrorHandler) {
        ConcurrentKafkaListenerContainerFactory<Object, Object> factory =
                new ConcurrentKafkaListenerContainerFactory<>();
        configurer.configure(factory, consumerFactory);
        factory.setErrorHandler(kafkaErrorHandler);
        factory.getContainerProperties().setDeliveryAttemptHeader(true);
        return factory;
    }
}
