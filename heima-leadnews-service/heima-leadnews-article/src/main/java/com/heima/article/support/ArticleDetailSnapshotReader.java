package com.heima.article.support;

import com.baomidou.mybatisplus.core.toolkit.Wrappers;
import com.heima.article.mapper.ApArticleContentMapper;
import com.heima.article.mapper.ApArticleMapper;
import com.heima.model.article.pojos.ApArticle;
import com.heima.model.article.pojos.ApArticleContent;
import lombok.extern.slf4j.Slf4j;
import org.springframework.jdbc.datasource.DataSourceUtils;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.transaction.support.TransactionSynchronizationManager;

import javax.sql.DataSource;
import java.sql.Connection;

/**
 * P1.3a：详情回源的「短读事务快照」读取器。
 *
 * <p>详情回源需要两次查询（文章 + 正文），必须读到同一个一致快照；但缓存命中、争锁、
 * 退避等待这些 Redis 动作**不能**包在这段事务里（否则会长期占用连接，P1.2 已经用
 * 类级 {@code @Transactional} 复现过这一点）。所以把两次查询收缩到一个只读短事务：
 * 事务只覆盖两条 SELECT，方法返回后连接立即归还，序列化与回填 Redis 都在事务之外。</p>
 *
 * <p>这是一个独立的 Spring bean，因此 {@code @Transactional} 由真实代理生效；
 * 不是 private 方法、也不是同类自调用。</p>
 *
 * <p>探针开启时（{@code -Darticle.detail.probe.file=...}），每次查询前后记录一条
 * {@code tx.trace} 事件，内容包括：事务是否 active / readOnly、事务资源的标识、
 * 该连接的对象标识、连接的真实 isolation 与 autoCommit。这样「两次 SELECT 用同一个连接、
 * 同一个事务资源」以及「隔离级别到底是什么」都有运行时原件，而不是调用方写的标签。</p>
 */
@Component
@Slf4j
public class ArticleDetailSnapshotReader {

    private final ApArticleMapper apArticleMapper;
    private final ApArticleContentMapper apArticleContentMapper;
    private final DataSource dataSource;
    private final DetailProbe probe;

    public ArticleDetailSnapshotReader(ApArticleMapper apArticleMapper,
                                       ApArticleContentMapper apArticleContentMapper,
                                       DataSource dataSource,
                                       DetailProbe probe) {
        this.apArticleMapper = apArticleMapper;
        this.apArticleContentMapper = apArticleContentMapper;
        this.dataSource = dataSource;
        this.probe = probe;
    }

    /**
     * 读取文章 + 正文的一致快照。只读事务，REQUIRED 传播：调用方（详情读路径）已显式
     * {@code NOT_SUPPORTED}，所以这里会新建一个只读事务；若将来有调用方已在事务中，则加入该事务。
     */
    @Transactional(readOnly = true, propagation = Propagation.REQUIRED)
    public Snapshot load(Long articleId) {
        trace("before_first_select", articleId);
        ApArticle article = apArticleMapper.selectById(articleId);
        trace("after_first_select", articleId);
        if (article == null) {
            trace("no_second_select", articleId);
            return new Snapshot(null, null);
        }
        ApArticleContent content = apArticleContentMapper.selectOne(
                Wrappers.<ApArticleContent>lambdaQuery().eq(ApArticleContent::getArticleId, articleId));
        trace("after_second_select", articleId);
        return new Snapshot(article, content);
    }

    /**
     * 记录真实的事务/连接身份。探针关闭时立即返回，不做任何额外取连接动作。
     * 连接通过 {@link DataSourceUtils#getConnection} 取当前事务已绑定的那一个（事务管理器在
     * begin 时就已绑定），因此这一步不会新建连接；{@link DataSourceUtils#releaseConnection}
     * 在事务内是空操作，不会打断事务。
     */
    private void trace(String phase, Long articleId) {
        if (probe == null || !probe.isEnabled()) {
            return;
        }
        boolean txActive = TransactionSynchronizationManager.isActualTransactionActive();
        boolean readOnly = TransactionSynchronizationManager.isCurrentTransactionReadOnly();
        boolean hasResource = TransactionSynchronizationManager.hasResource(dataSource);
        Object resource = hasResource ? TransactionSynchronizationManager.getResource(dataSource) : null;
        int isolation = -1;
        boolean autoCommit = true;
        String connId = "-";
        Connection conn = null;
        try {
            conn = DataSourceUtils.getConnection(dataSource);
            isolation = conn.getTransactionIsolation();
            autoCommit = conn.getAutoCommit();
            connId = Integer.toHexString(System.identityHashCode(conn));
        } catch (Exception e) {
            connId = "error:" + e.getClass().getSimpleName();
        } finally {
            if (conn != null) {
                DataSourceUtils.releaseConnection(conn, dataSource);
            }
        }
        probe.event("tx.trace", 0L, articleId,
                "phase=" + phase
                        + " txActive=" + txActive
                        + " readOnly=" + readOnly
                        + " resourceBound=" + hasResource
                        + " resourceId=" + (resource == null ? "-" : Integer.toHexString(System.identityHashCode(resource)))
                        + " connId=" + connId
                        + " isolation=" + isolation
                        + " autoCommit=" + autoCommit);
    }

    /** 两次查询的结果载体；{@code article == null} 表示文章不存在（调用方写空值占位） */
    public static final class Snapshot {
        private final ApArticle article;
        private final ApArticleContent content;

        public Snapshot(ApArticle article, ApArticleContent content) {
            this.article = article;
            this.content = content;
        }

        public ApArticle getArticle() {
            return article;
        }

        public ApArticleContent getContent() {
            return content;
        }
    }
}
