package com.heima.article.service.impl;

import com.alibaba.fastjson.JSON;
import com.alibaba.fastjson.JSONArray;
import com.baomidou.mybatisplus.core.toolkit.Wrappers;
import com.heima.article.mapper.ApArticleContentMapper;
import com.heima.article.support.DetailCacheInvalidator;
import com.heima.article.support.DetailProbe;
import com.heima.article.service.ApArticleService;
import com.heima.article.service.ArticleFreemarkerService;
import com.heima.common.constants.ArticleConstants;
import com.heima.file.service.FileStorageService;
import com.heima.model.article.pojos.ApArticle;
import com.heima.model.search.vos.ArticleIndexEvent;
import com.heima.model.search.vos.SearchArticleVo;
import freemarker.template.Configuration;
import freemarker.template.Template;
import lombok.extern.slf4j.Slf4j;
import org.apache.commons.lang3.StringUtils;
import org.springframework.beans.BeanUtils;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.kafka.core.KafkaTemplate;
import org.apache.kafka.clients.producer.ProducerRecord;
import org.apache.kafka.clients.producer.RecordMetadata;
import org.springframework.kafka.support.SendResult;
import org.springframework.util.concurrent.ListenableFuture;
import org.springframework.scheduling.annotation.Async;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.io.ByteArrayInputStream;
import java.nio.charset.StandardCharsets;
import java.io.InputStream;
import java.io.StringWriter;
import java.util.HashMap;
import java.util.Map;

@Service
@Slf4j
@Transactional
public class ArticleFreemarkerServiceImpl implements ArticleFreemarkerService {

    @Autowired
    private ApArticleContentMapper apArticleContentMapper;

    @Autowired
    private Configuration configuration;

    @Autowired
    private FileStorageService fileStorageService;

    @Autowired
    private ApArticleService apArticleService;

    /** P1.3b：static_url 写入后登记详情缓存失效（走同一失效器，异步工作线程事务提交后执行） */
    @Autowired
    private DetailCacheInvalidator detailCacheInvalidator;

    /** P1.3b：实验探针（默认关闭），只记录异步线程/事务身份与写入结果 */
    @Autowired
    private DetailProbe probe;

    /**
     * 生成静态文件上传到minIO中
     * @param apArticle
     * @param content
     */
    @Async
    @Override
    public void buildArticleToMinIO(ApArticle apArticle, String content) {
        //已知文章的id
        //4.1 获取文章内容
        if(StringUtils.isNotBlank(content)){
            //4.2 文章内容通过freemarker生成html文件
            Template template = null;
            StringWriter out = new StringWriter();
            try {
                template = configuration.getTemplate("article.ftl");
                //数据模型
                Map<String,Object> contentDataModel = new HashMap<>();
                contentDataModel.put("content", JSONArray.parseArray(content));
                //合成
                template.process(contentDataModel,out);
            } catch (Exception e) {
                e.printStackTrace();
            }


            //4.3 把html文件上传到minio中
            InputStream in = new ByteArrayInputStream(out.toString().getBytes());
            String path = fileStorageService.uploadHtmlFile("", apArticle.getId() + ".html", in);


            //4.4 修改ap_article表，保存static_url字段
            boolean staticUrlUpdated = apArticleService.update(Wrappers.<ApArticle>lambdaUpdate().eq(ApArticle::getId,apArticle.getId())
                    .set(ApArticle::getStaticUrl,path));

            //P1.3b: 只有真实更新成功才记录成功写入并登记提交后失效。update() 在 0 行时返回 false，
            //因此目标行不存在时不得报 static_url.updated、也不得登记失效（回滚/零行都不删缓存）。
            //取舍：下面原有的消息流程保持不动（本卡之前它对每次调用都会执行），只纠正“已成功写入并失效”的表述。
            if (staticUrlUpdated) {
                probe.event("static_url.updated", 0L, apArticle.getId(),
                        "path=" + path + " inAsyncWorker=true"
                                + " txActive=" + org.springframework.transaction.support.TransactionSynchronizationManager.isActualTransactionActive());
                detailCacheInvalidator.invalidateAfterWrite(apArticle.getId(), "static_url:afterUpdate");
            } else {
                probe.event("static_url.update_skipped", 0L, apArticle.getId(),
                        "path=" + path + " reason=zero_rows inAsyncWorker=true"
                                + " txActive=" + org.springframework.transaction.support.TransactionSynchronizationManager.isActualTransactionActive());
            }
            createArticleESIndex(apArticle,content,path);

        }
    }

    @Autowired
    private KafkaTemplate<String,String> kafkaTemplate;

    @Value("${leadnews.article.index.topic:article.es.sync.topic}")
    private String articleIndexTopic = ArticleConstants.ARTICLE_ES_SYNC_TOPIC;

    /**
     * 送消息，创建索引
     * @param apArticle
     * @param content
     * @param path
     */
    private void createArticleESIndex(ApArticle apArticle, String content, String path) {
        SearchArticleVo vo = new SearchArticleVo();
        BeanUtils.copyProperties(apArticle,vo);
        vo.setContent(content);
        vo.setStaticUrl(path);

        // Create one identity and immutable serialized payload for this indexing invocation.
        // Kafka transport retries and DLT replay keep these bytes; another invocation gets a new eventId.
        final ArticleIndexEvent event = ArticleIndexEvent.create(vo);
        final String payload = JSON.toJSONString(event);
        final int payloadUtf8Bytes = payload.getBytes(StandardCharsets.UTF_8).length;
        final ProducerRecord<String, String> record = new ProducerRecord<>(articleIndexTopic, event.getArticleId(), payload);
        record.headers().add("eventId", event.getEventId().getBytes(StandardCharsets.UTF_8));
        //P2.0：发送结果必须有成功/失败观测。原实现直接丢弃 send 的返回值，broker 不可用或发送失败时
        //调用方与日志都拿不到任何结果。这里只加观测，不改成同步等待，也不声称解决了数据库与消息的原子性。
        //articleId key groups the article on a partition; it does not prevent old replays overwriting newer content.
        ListenableFuture<SendResult<String, String>> future;
        try {
            future = kafkaTemplate.send(record);
        } catch (RuntimeException e) {
            //KafkaTemplate 除异步回调外还有同步抛出路径（producer 已关闭、序列化失败等会直接抛
            //KafkaException("Send failed", ...)）。这里补一条带 articleId 的观测，并保持原语义继续上抛。
            log.error("[ES-SYNC-SEND] sync-throw articleId={} topic={} payloadUtf8Bytes={} eventId={} error={}",
                    event.getArticleId(), articleIndexTopic, payloadUtf8Bytes, event.getEventId(), e.toString());
            throw e;
        }
        future.addCallback(
                result -> {
                    RecordMetadata md = result == null ? null : result.getRecordMetadata();
                    log.info("[ES-SYNC-SEND] ok articleId={} topic={} partition={} offset={} payloadUtf8Bytes={} eventId={}",
                            event.getArticleId(),
                            md == null ? "?" : md.topic(),
                            md == null ? -1 : md.partition(),
                            md == null ? -1L : md.offset(),
                            payloadUtf8Bytes, event.getEventId());
                },
                ex -> log.error("[ES-SYNC-SEND] fail articleId={} topic={} payloadUtf8Bytes={} eventId={} error={}",
                        event.getArticleId(), articleIndexTopic, payloadUtf8Bytes, event.getEventId(),
                        ex == null ? "null" : ex.toString()));
    }

}
