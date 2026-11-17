package com.heima.article.service.impl;

import com.alibaba.fastjson.JSON;
import com.baomidou.mybatisplus.core.conditions.query.LambdaQueryWrapper;
import com.baomidou.mybatisplus.core.metadata.IPage;
import com.baomidou.mybatisplus.core.toolkit.Wrappers;
import com.baomidou.mybatisplus.extension.plugins.pagination.Page;
import com.baomidou.mybatisplus.extension.service.impl.ServiceImpl;
import com.heima.article.mapper.ApArticleConfigMapper;
import com.heima.article.mapper.ApArticleContentMapper;
import com.heima.article.mapper.ApArticleMapper;
import com.heima.article.service.ApArticleService;
import com.heima.article.service.ArticleFreemarkerService;
import com.heima.common.constants.ArticleConstants;
import com.heima.common.constants.BehaviorConstants;
import com.heima.common.redis.CacheService;
import com.heima.model.article.dtos.ArticleCommentDto;
import com.heima.model.article.dtos.ArticleDto;
import com.heima.model.article.dtos.ArticleHomeDto;

import com.heima.model.article.dtos.ArticleInfoDto;
import com.heima.model.article.pojos.ApArticle;
import com.heima.model.article.pojos.ApArticleConfig;
import com.heima.model.article.pojos.ApArticleContent;
import com.heima.model.article.vos.ArticleCommnetVo;
import com.heima.model.article.vos.HotArticleVo;
import com.heima.model.common.dtos.PageResponseResult;
import com.heima.model.common.dtos.ResponseResult;
import com.heima.model.common.enums.AppHttpCodeEnum;
import com.heima.model.mess.ArticleVisitStreamMess;
import com.heima.model.user.pojos.ApUser;
import com.heima.model.wemedia.dtos.StatisticsDto;
import com.heima.utils.common.DateUtils;
import org.springframework.beans.factory.annotation.Value;
import com.heima.article.support.DetailProbe;
import com.heima.article.support.ArticleDetailSnapshotReader;
import com.heima.article.support.DetailCacheInvalidator;
import com.heima.utils.thread.AppThreadLocalUtil;
import lombok.extern.slf4j.Slf4j;
import org.apache.commons.lang3.StringUtils;
import org.springframework.beans.BeanUtils;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.util.*;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.ThreadLocalRandom;
import java.util.concurrent.TimeUnit;
import java.util.stream.Collectors;
import java.util.concurrent.atomic.AtomicLong;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.heima.model.article.vos.ArticleDetailVo;

@Service
//P1.3a：保留类级事务边界（newPage / findNewsComments / saveArticle / updateScore 等原有语义不变），
//只把详情读路径用 NOT_SUPPORTED 显式移出事务；详情两次查询另由 ArticleDetailSnapshotReader 的短读事务保证快照一致。
@Transactional
@Slf4j
public class ApArticleServiceImpl  extends ServiceImpl<ApArticleMapper, ApArticle> implements ApArticleService {

    // 单页最大加载的数字
    private final static short MAX_PAGE_SIZE = 50;

    /** 文章详情缓存 key 前缀 */
    private static final String ARTICLE_DETAIL_KEY = "article:detail:";
    /** 空值占位符：用于拦住对不存在 ID 的重复查询 */
    private static final String NULL_CACHE_VALUE = "__NULL__";
    /**
     * TTL 默认值（秒）。1800 + 0~299 抖动、空值 60 秒是**当前代码原值**，作为候选保留，
     * 不是调优结果。P1.1 起改为可通过配置覆盖，便于在隔离环境做 TTL/空值过期功能试验；
     * 正式取值仍需由实测资源与陈旧窗口要求决定（P1.1 只给候选表）。
     */
    private static final long DEFAULT_DETAIL_EXPIRE_SECONDS = 30 * 60L;
    private static final long DEFAULT_NULL_EXPIRE_SECONDS = 60L;
    private static final long DEFAULT_EXPIRE_JITTER_SECONDS = 300L;
    //注意：延迟二次删除的等待窗口已移到 DetailCacheInvalidator（P1.3a），本类不再持有调度器

    /** 详情请求序号：只用于把结构化日志与单次请求对应，不参与业务判断 */
    private static final AtomicLong DETAIL_REQ_SEQ = new AtomicLong();

    /** 回源尝试序号：只用于把同一次请求的多次回源尝试区分开（P1.2 事件流水） */
    private static final AtomicLong DB_ATTEMPT_SEQ = new AtomicLong();

    /**
     * 详情缓存开关，默认 true（正常 Cache Aside 行为）。
     * 仅用于 P1.0 的同接口受控对照：为 false 时完全不读写 Redis，直接查库（A 组）。
     * 该 key 刻意不写入 Nacos 配置，避免远端配置覆盖启动参数。
     */
    @Value("${article.detail.cache.enabled:true}")
    private boolean articleDetailCacheEnabled;

    /**
     * 详情缓存 TTL（秒），默认取原值 1800。仅用于隔离环境的 TTL/过期功能试验；
     * 缩短它得到的命中率**不代表**正式 TTL 的效果。
     */
    @Value("${article.detail.expire-seconds:1800}")
    private long articleDetailExpireSeconds;

    /** 空值占位 TTL（秒），默认原值 60；补录可见性窗口由它决定 */
    @Value("${article.detail.null-expire-seconds:60}")
    private long articleDetailNullExpireSeconds;

    /**
     * 锁租期（毫秒）。默认沿用原来的 3 秒，本次不调优；较短租期只用于故障试验。
     * 必须为正，非法配置回退默认值并告警。
     */
    @Value("${article.detail.lock.expire-millis:3000}")
    private long lockExpireMillis;

    /**
     * 未获锁时的等待预算（毫秒）。等待预算必须有限且小于租期：预算耗尽即返回明确失败，
     * 不允许退化成「全部无锁回源」。默认 1000 ms，小于租期 1/3。
     */
    @Value("${article.detail.lock.wait-budget-millis:1000}")
    private long lockWaitBudgetMillis;

    /** 退避基数（毫秒），按 2^attempt 增长，上限见 lockWaitBackoffMaxMillis */
    @Value("${article.detail.lock.wait-backoff-millis:10}")
    private long lockWaitBackoffMillis;

    /** 退避上限（毫秒），避免等待者长时间不重试 */
    @Value("${article.detail.lock.wait-backoff-max-millis:50}")
    private long lockWaitBackoffMaxMillis;

    /** 配置自检：非法值回退默认并告警，不让错误配置把等待变成无界或把租期变成 0 */
    @javax.annotation.PostConstruct
    void validateLockSettings() {
        if (lockExpireMillis <= 0) {
            log.warn("article.detail.lock.expire-millis={} 非法，回退 3000ms", lockExpireMillis);
            lockExpireMillis = 3000L;
        }
        if (lockWaitBudgetMillis <= 0) {
            log.warn("article.detail.lock.wait-budget-millis={} 非法，回退 1000ms", lockWaitBudgetMillis);
            lockWaitBudgetMillis = 1000L;
        }
        if (lockWaitBudgetMillis >= lockExpireMillis) {
            long capped = Math.max(1L, lockExpireMillis / 2);
            log.warn("等待预算 {}ms 不小于租期 {}ms，收敛为 {}ms", lockWaitBudgetMillis, lockExpireMillis, capped);
            lockWaitBudgetMillis = capped;
        }
        if (lockWaitBackoffMillis <= 0) { lockWaitBackoffMillis = 10L; }
        if (lockWaitBackoffMaxMillis < lockWaitBackoffMillis) { lockWaitBackoffMaxMillis = lockWaitBackoffMillis; }
    }

    /** TTL 随机抖动上限（秒，取 [0, jitter)），默认原值 300；设为 0 可得到确定 TTL，便于试验断言 */
    @Value("${article.detail.expire-jitter-seconds:300}")
    private long articleDetailExpireJitterSeconds;

    /** 与 HTTP 响应共用同一个 ObjectMapper，保证缓存 JSON 与响应体同构（CACHE-006） */
    @Autowired
    private ObjectMapper objectMapper;

    /** P1.2 实验探针：默认关闭，只有 -Darticle.detail.probe.file 指向配置时才写事件/注入延迟 */
    @Autowired
    private DetailProbe probe;

    /** P1.3a：详情回源的短只读事务快照读取器（两次 SELECT 的一致快照，连接只在这段事务里占用） */
    @Autowired
    private ArticleDetailSnapshotReader articleDetailSnapshotReader;

    /** P1.3a：写路径的详情缓存失效器（有事务登记 afterCommit，无事务立即执行） */
    @Autowired
    private DetailCacheInvalidator detailCacheInvalidator;

    @Autowired
    private ApArticleMapper apArticleMapper;

    /**
     * 根据参数加载文章列表
     * @param loadtype 1为加载更多  2为加载最新
     * @param dto
     * @return
     */
    @Override
    public ResponseResult load(Short loadtype, ArticleHomeDto dto) {
        //1.校验参数
        Integer size = dto.getSize();
        if(size == null || size == 0){
            size = 10;
        }
        size = Math.min(size,MAX_PAGE_SIZE);
        dto.setSize(size);

        //类型参数检验
        if(!loadtype.equals(ArticleConstants.LOADTYPE_LOAD_MORE)&&!loadtype.equals(ArticleConstants.LOADTYPE_LOAD_NEW)){
            loadtype = ArticleConstants.LOADTYPE_LOAD_MORE;
        }
        //文章频道校验
        if(StringUtils.isEmpty(dto.getTag())){
            dto.setTag(ArticleConstants.DEFAULT_TAG);
        }

        //时间校验
        if(dto.getMaxBehotTime() == null) dto.setMaxBehotTime(new Date());
        if(dto.getMinBehotTime() == null) dto.setMinBehotTime(new Date());
        //2.查询数据
        List<ApArticle> apArticles = apArticleMapper.loadArticleList(dto, loadtype);

        //3.结果封装
        ResponseResult responseResult = ResponseResult.okResult(apArticles);
        return responseResult;
    }

    /**
     * 加载文章列表
     * @param dto
     * @param type      1 加载更多   2 加载最新
     * @param firstPage true  是首页  flase 非首页
     * @return
     */
    @Override
    public ResponseResult load2(ArticleHomeDto dto, Short type, boolean firstPage) {
        if(firstPage){
            String jsonStr = cacheService.get(ArticleConstants.HOT_ARTICLE_FIRST_PAGE + dto.getTag());
            if(StringUtils.isNotBlank(jsonStr)){
                List<HotArticleVo> hotArticleVoList = JSON.parseArray(jsonStr, HotArticleVo.class);
                ResponseResult responseResult = ResponseResult.okResult(hotArticleVoList);
                return responseResult;
            }
        }
        return load(type,dto);
    }

    @Autowired
    private ApArticleConfigMapper apArticleConfigMapper;

    @Autowired
    private ApArticleContentMapper apArticleContentMapper;

    @Autowired
    private ArticleFreemarkerService articleFreemarkerService;

    /**
     * 保存app端相关文章
     * @param dto
     * @return
     */
    public ResponseResult saveArticle(ArticleDto dto) {
        //1.检查参数
        if(dto == null){
            return ResponseResult.errorResult(AppHttpCodeEnum.PARAM_INVALID);
        }

        ApArticle apArticle = new ApArticle();
        BeanUtils.copyProperties(dto,apArticle);

        //2.判断是否存在id
        if(dto.getId() == null){
            //2.1 不存在id  保存  文章  文章配置  文章内容

            //保存文章
            save(apArticle);

            //保存配置
            ApArticleConfig apArticleConfig = new ApArticleConfig(apArticle.getId());
            apArticleConfigMapper.insert(apArticleConfig);

            //保存 文章内容
            ApArticleContent apArticleContent = new ApArticleContent();
            apArticleContent.setArticleId(apArticle.getId());
            apArticleContent.setContent(dto.getContent());
            apArticleContentMapper.insert(apArticleContent);

            //新建后清除该 ID 可能存在的空值占位（P1.1：补录同 ID 必须可见）。
            //正常流程下 ID 由 ID_WORKER 生成、此前不会有占位；但若同一 ID 曾被查询并写入 __NULL__，
            //不清理就会让新文章在空值 TTL 内持续返回 1002。
            //P1.3a：登记「成功提交之后」再失效（提交前只登记，不删），避免两次删除都早于提交
            detailCacheInvalidator.invalidateAfterWrite(apArticle.getId(), "saveArticle:create");

        }else {
            //2.2 存在id   修改  文章  文章内容

            //修改  文章
            updateById(apArticle);

            //修改文章内容
            ApArticleContent apArticleContent = apArticleContentMapper.selectOne(Wrappers.<ApArticleContent>lambdaQuery().eq(ApArticleContent::getArticleId, dto.getId()));
            apArticleContent.setContent(dto.getContent());
            apArticleContentMapper.updateById(apArticleContent);

            //先更库、再删缓存，并延迟二次删除
            //P1.3a：失效不再在事务内立刻执行，而是登记到「成功提交之后」；回滚不执行。
            //第二次删除（+500ms）仍沿用现有策略，由失效器统一安排。
            detailCacheInvalidator.invalidateAfterWrite(dto.getId(), "saveArticle:update");
        }

        //异步调用 生成静态文件上传到minio中
        articleFreemarkerService.buildArticleToMinIO(apArticle,dto.getContent());


        //3.结果返回  文章的id
        //P1.3a 夹具：把写事务停在 COMMIT 之前（只在精确配置了该 articleId 的实例上生效，默认 0）
        Long invalidationTargetId = dto.getId() != null ? dto.getId() : apArticle.getId();
        probe.holdBeforeCommit(invalidationTargetId, 0L);
        //P1.3a 夹具：登记失效之后受控回滚，用于证明「回滚不触发成功提交的失效」
        if (probe.rollbackConfiguredFor(invalidationTargetId)) {
            probe.event("tx.controlled_rollback", 0L, invalidationTargetId, "phase=after_register");
            throw new IllegalStateException("P1.3a controlled rollback after registering the invalidation");
        }

        return ResponseResult.okResult(apArticle.getId());
    }

    @Autowired
    private CacheService cacheService;

    @Override
    public ResponseResult loadArticleBehavior(ArticleInfoDto dto) {

        //0.检查参数
        if (dto == null || dto.getArticleId() == null || dto.getAuthorId() == null) {
            return ResponseResult.errorResult(AppHttpCodeEnum.PARAM_INVALID);
        }

        //{ "isfollow": true, "islike": true,"isunlike": false,"iscollection": true }
        boolean isfollow = false, islike = false, isunlike = false, iscollection = false;

        ApUser user = AppThreadLocalUtil.getUser();
        if(user != null){
            //喜欢行为
            String likeBehaviorJson = (String) cacheService.hGet(BehaviorConstants.LIKE_BEHAVIOR + dto.getArticleId().toString(), user.getId().toString());
            if(StringUtils.isNotBlank(likeBehaviorJson)){
                islike = true;
            }
            //不喜欢的行为
            String unLikeBehaviorJson = (String) cacheService.hGet(BehaviorConstants.UN_LIKE_BEHAVIOR + dto.getArticleId().toString(), user.getId().toString());
            if(StringUtils.isNotBlank(unLikeBehaviorJson)){
                isunlike = true;
            }
            //是否收藏
            String collctionJson = (String) cacheService.hGet(BehaviorConstants.COLLECTION_BEHAVIOR+user.getId(),dto.getArticleId().toString());
            if(StringUtils.isNotBlank(collctionJson)){
                iscollection = true;
            }

            //是否关注
            Double score = cacheService.zScore(BehaviorConstants.APUSER_FOLLOW_RELATION + user.getId(), dto.getAuthorId().toString());
            System.out.println(score);
            if(score != null){
                isfollow = true;
            }

        }

        Map<String, Object> resultMap = new HashMap<>();
        resultMap.put("isfollow", isfollow);
        resultMap.put("islike", islike);
        resultMap.put("isunlike", isunlike);
        resultMap.put("iscollection", iscollection);

        return ResponseResult.okResult(resultMap);
    }

    /**
     * 查询文章详情。
     * 读路径：缓存命中直接返回；未命中时用互斥锁限制只有一个线程回源（防击穿）；
     * 数据库查不到时写入空值占位（防穿透）；正常缓存的 TTL 加随机偏移（防雪崩）。
     *
     * <p>P1.0 契约修复（CACHE-006）：冷读与热读都用 {@link ArticleDetailVo} 承载，并用同一个 Jackson
     * ObjectMapper 做写缓存/读缓存，因此 {@code article.id} 的类型（字符串）与 null/缺省策略在两条路径上一致。
     * 修复前热读走 fastjson 转 Map，绕过了项目 ConfusionModule 把 {@code id} 写成字符串的约定，
     * 导致同一接口冷热响应的 {@code id} 一个字符串一个数字；文章 ID 为 19 位 Long，前端按 double 解析会丢精度。</p>
     */
    @Transactional(propagation = Propagation.NOT_SUPPORTED)
    @Override
    public ResponseResult getArticleDetail(Long id) {
        if (id == null) {
            return ResponseResult.errorResult(AppHttpCodeEnum.PARAM_INVALID);
        }
        long startNanos = System.nanoTime();
        long reqId = DETAIL_REQ_SEQ.incrementAndGet();
        String cacheKey = ARTICLE_DETAIL_KEY + id;
        probe.event("request.start", reqId, id, "cacheKey=" + cacheKey);

        // 受控对照 A 组：完全不读写 Redis，直接查库
        if (!articleDetailCacheEnabled) {
            DetailCall call = queryArticleDetail(id, null, false, reqId);
            logDetailMetric(reqId, id, "DIRECT", call.result, "DISABLED", call.dbSelect, startNanos);
            return call.response;
        }

        //1.先查缓存（R2：故障注入放在实际 I/O 的 try 边界内，异常走分类处理而不是全局兜底）
        String cached;
        try {
            cached = redisIo("read", reqId, id, () -> cacheService.get(cacheKey));
        } catch (RuntimeException e) {
            //首读 Redis 不可用：明确失败，不降级为无锁回源
            logDetailMetric(reqId, id, "CACHE", "FAIL_REDIS_ERROR_READ", "ERROR", 0, startNanos);
            return ResponseResult.errorResult(AppHttpCodeEnum.SERVER_ERROR);
        }
        probe.event("cache.read", reqId, id, "hit=" + (cached != null));
        if (cached != null) {
            DetailCall hit = fromDetailCache(cached);
            if (hit != null) {
                logDetailMetric(reqId, id, "CACHE", hit.result, "NONE", 0, startNanos);
                return hit.response;
            }
            //缓存内容无法反序列化时按未命中处理，不让脏缓存变成 500
            log.warn("文章详情缓存无法反序列化，按未命中处理, articleId={}", id);
        }

        //2.回源前加互斥锁，拿不到锁说明已有线程在回源
        //P1.2 修复（CACHE-001/002）：锁值改为唯一令牌，释放走 Redis 原子 compare-and-delete；
        //未获锁的请求在有限预算内循环「重查缓存 + 退避 + 重新争锁」，预算耗尽或 Redis 不可用时
        //返回明确的 503 失败，而不是让所有等待者无锁回源。
        String lockKey = cacheKey + ":lock";
        String token = UUID.randomUUID().toString();

        long waitDeadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(lockWaitBudgetMillis);
        int attempt = 0;
        while (true) {
            //R1：发起争锁之前先检查期限。睡眠或调度停顿后剩余预算已耗尽时，不得再发起新的争锁/回源。
            long beforeAttemptNanos = waitDeadline - System.nanoTime();
            if (beforeAttemptNanos <= 0) {
                probe.event("wait.end", reqId, id, "outcome=budget_exhausted attempts=" + attempt
                        + " phase=before_attempt remainingMs=" + (beforeAttemptNanos / 1_000_000L));
                logDetailMetric(reqId, id, "CACHE", "FAIL_WAIT_BUDGET_EXHAUSTED", "BUDGET_EXHAUSTED", 0, startNanos);
                return ResponseResult.errorResult(AppHttpCodeEnum.SERVER_ERROR);
            }
            attempt++;
            probe.event("lock.attempt", reqId, id, "key=" + lockKey + " attempt=" + attempt
                    + " remainingMs=" + (beforeAttemptNanos / 1_000_000L));

            Boolean locked;
            try {
                locked = redisIo("lock", reqId, id,
                        () -> cacheService.getstringRedisTemplate().opsForValue()
                                .setIfAbsent(lockKey, token, lockExpireMillis, TimeUnit.MILLISECONDS));
            } catch (RuntimeException e) {
                //Redis 争锁不可用：明确失败，不降级为无锁回源
                logDetailMetric(reqId, id, "CACHE", "FAIL_REDIS_ERROR_LOCK", "ERROR", 0, startNanos);
                return ResponseResult.errorResult(AppHttpCodeEnum.SERVER_ERROR);
            }
            if (Boolean.TRUE.equals(locked)) {
                long lateNanos = System.nanoTime() - waitDeadline;
                if (lateNanos > 0) {
                    //R1：本次 SET NX 在预算内发起、但晚到才确认成功，此时期限已过。
                    //不进入回源；用令牌 compare-delete 只清理自己刚拿到的锁（不会删别人），然后按预算失败返回。
                    probe.event("lock.late_acquire", reqId, id, "attempt=" + attempt
                            + " lateByMs=" + (lateNanos / 1_000_000L) + " action=release_own_token_then_fail");
                    releaseLock(lockKey, token, reqId, id);
                    probe.event("wait.end", reqId, id, "outcome=budget_exhausted attempts=" + attempt
                            + " phase=late_acquire");
                    logDetailMetric(reqId, id, "CACHE", "FAIL_WAIT_BUDGET_EXHAUSTED", "BUDGET_EXHAUSTED", 0, startNanos);
                    return ResponseResult.errorResult(AppHttpCodeEnum.SERVER_ERROR);
                }
                probe.event("lock.acquired", reqId, id,
                        "lockValue=" + token + " leaseMs=" + lockExpireMillis + " attempts=" + attempt);
                break;
            }
            probe.event("lock.fail", reqId, id, "attempt=" + attempt + " budgetMs=" + lockWaitBudgetMillis);

            //R1：SET NX 可能在预算内发起，却把剩余预算耗光之后才返回 false。重查缓存同样是一次 Redis I/O，
            //不能在越过期限之后再新发一次 I/O：这里先检查期限，过期直接按预算失败，不发 GET、不进入退避。
            long afterLockFailNanos = waitDeadline - System.nanoTime();
            if (afterLockFailNanos <= 0) {
                probe.event("wait.end", reqId, id, "outcome=budget_exhausted attempts=" + attempt
                        + " phase=before_recheck remainingMs=" + (afterLockFailNanos / 1_000_000L));
                logDetailMetric(reqId, id, "CACHE", "FAIL_WAIT_BUDGET_EXHAUSTED", "BUDGET_EXHAUSTED", 0, startNanos);
                return ResponseResult.errorResult(AppHttpCodeEnum.SERVER_ERROR);
            }

            //未获锁：先重查缓存（持有者可能刚写完），再按剩余预算退避
            DetailCall hit = recheckCacheAfterLockFail(reqId, id, cacheKey, startNanos);
            if (hit != null) {
                probe.event("wait.end", reqId, id, "outcome=hit attempts=" + attempt);
                logDetailMetric(reqId, id, "CACHE", hit.result, "WAIT_THEN_HIT", 0, startNanos);
                return hit.response;
            }
            long remainingNanos = waitDeadline - System.nanoTime();
            if (remainingNanos <= 0) {
                probe.event("wait.end", reqId, id, "outcome=budget_exhausted attempts=" + attempt
                        + " phase=after_recheck remainingMs=0");
                logDetailMetric(reqId, id, "CACHE", "FAIL_WAIT_BUDGET_EXHAUSTED", "BUDGET_EXHAUSTED", 0, startNanos);
                return ResponseResult.errorResult(AppHttpCodeEnum.SERVER_ERROR);
            }
            long sleepMillis = Math.min(remainingNanos / 1_000_000L, nextBackoffMillis(attempt));
            if (sleepMillis <= 0) { sleepMillis = 1; }
            //实验夹具：仅在探针配置指定该 articleId 时，在**即将睡眠等待**的时刻注入一次中断。
            //必须先写事件再置中断位——中断位一旦置上，探针的文件写入会抛 ClosedByInterruptException。
            probe.event("wait.pre_sleep", reqId, id, "attempt=" + attempt + " sleepMs=" + sleepMillis
                    + " remainingMs=" + (remainingNanos / 1_000_000L)
                    + " cfgInterrupt=" + probe.interruptConfiguredFor(id));
            if (probe.interruptConfiguredFor(id)) {
                probe.event("interrupt.injected", reqId, id, "phase=before_sleep attempt=" + attempt);
                Thread.currentThread().interrupt();
            }
            try {
                Thread.sleep(sleepMillis);
            } catch (InterruptedException e) {
                //线程在等待中被中断：结束等待，不继续无界等待，也不无锁回源。
                //捕获事实用 interrupt_caught 记录；不从已被 Thread.sleep 清除的标记反推“检测到中断”。
                probe.event("interrupt_caught", reqId, id, "phase=wait_sleep attempt=" + attempt
                        + " exception=InterruptedException");
                probe.event("wait.end", reqId, id, "outcome=interrupted attempts=" + attempt);
                logDetailMetric(reqId, id, "CACHE", "FAIL_INTERRUPTED", "INTERRUPTED", 0, startNanos);
                return ResponseResult.errorResult(AppHttpCodeEnum.SERVER_ERROR);
            }
            //R1 夹具：睡眠之后插入一次调度停顿，复现「预算被停顿吃掉后仍想再次争锁」的场景；
            //停顿返回后循环回到顶部，那里会先检查剩余预算，过期即不再发起争锁。
            probe.stallIfConfigured(id, reqId);
        }

        try {
            //实验注入：持锁超过租期（仅在探针配置指定该 articleId 时生效）
            probe.holdAfterLock(id, reqId);
            //3.双重检查：等锁期间可能已有其他线程写入
            String recheck;
            try {
                recheck = redisIo("recheck_after_lock", reqId, id, () -> cacheService.get(cacheKey));
            } catch (RuntimeException e) {
                //已持锁但双重检查读失败：不冒险回源写缓存，释放自己的锁后明确失败
                logDetailMetric(reqId, id, "CACHE", "FAIL_REDIS_ERROR_READ", "ERROR", 0, startNanos);
                return ResponseResult.errorResult(AppHttpCodeEnum.SERVER_ERROR);
            }
            if (recheck != null) {
                DetailCall hit = fromDetailCache(recheck);
                if (hit != null) {
                    logDetailMetric(reqId, id, "CACHE", hit.result, "DOUBLE_CHECK_HIT", 0, startNanos);
                    return hit.response;
                }
            }
            DetailCall call = queryArticleDetail(id, cacheKey, true, reqId);
            logDetailMetric(reqId, id, "CACHE", call.result, "ACQUIRED", call.dbSelect, startNanos);
            return call.response;
        } finally {
            releaseLock(lockKey, token, reqId, id);
        }
    }

    /**
     * R2：所有 Redis I/O 的统一入口。故障注入、耗时、异常都在**同一个 try 边界**内，
     * 因此「注入的故障」和「真实故障」走完全相同的分类路径，可以从事件流核对，
     * 而不是靠全局 ExceptionCatch 返回 503 来推断。
     */
    private <T> T redisIo(String stage, long reqId, Long id, java.util.function.Supplier<T> call) {
        long t0 = System.nanoTime();
        probe.event("io.begin", reqId, id, "stage=" + stage);
        try {
            //注入点位于实际调用之前、同一个 try 内
            probe.failRedisIfConfigured(stage, reqId, id);
            T value = call.get();
            probe.event("io.end", reqId, id, "stage=" + stage
                    + " elapsedMs=" + ((System.nanoTime() - t0) / 1_000_000L) + " result=ok");
            return value;
        } catch (RuntimeException e) {
            probe.event("io.error", reqId, id, "stage=" + stage
                    + " elapsedMs=" + ((System.nanoTime() - t0) / 1_000_000L)
                    + " error=" + e.getClass().getSimpleName());
            throw e;
        }
    }

    /**
     * 未获锁时重查缓存。Redis 读失败按「读不到」处理并向调用方返回 null，
     * 由等待循环在预算内继续；连续失败最终由预算耗尽路径明确失败。
     */
    private DetailCall recheckCacheAfterLockFail(long reqId, Long id, String cacheKey, long startNanos) {
        String cached;
        try {
            cached = redisIo("recheck", reqId, id, () -> cacheService.get(cacheKey));
        } catch (RuntimeException e) {
            //重查失败按读不到处理，等待循环继续；这里已由 io.error 记录分类
            return null;
        }
        if (cached == null) {
            return null;
        }
        DetailCall hit = fromDetailCache(cached);
        probe.event("cache.read", reqId, id, "hit=" + (hit != null) + " during_wait=true");
        return hit;
    }

    /**
     * 有界退避：base * 2^attempt，先按 lockWaitBackoffMaxMillis 封顶，再叠加最多 50% 抖动；
     * 实际睡眠还会被剩余预算截断，所以不是「严格封顶 max」。
     */
    private long nextBackoffMillis(int attempt) {
        long exp = Math.min(attempt, 6);
        long base = lockWaitBackoffMillis * (1L << exp);
        long capped = Math.min(base, lockWaitBackoffMaxMillis);
        long jitter = ThreadLocalRandom.current().nextLong(Math.max(1L, capped / 2 + 1));
        return Math.max(1L, capped + jitter);
    }

    /**
     * 只释放自己持有的锁：用 Redis 原子 compare-and-delete（Lua），不做 GET 后 DEL。
     * 释放失败不改变本次请求已经得到的响应，只留痕；残留锁靠租期回收。
     */
    private void releaseLock(String lockKey, String token, long reqId, Long id) {
        try {
            //走统一 I/O 入口：注入点与实际调用在同一个 try 内，分类可核对（R2）
            Long deleted = redisIo("release", reqId, id,
                    () -> cacheService.releaseIfValueEquals(lockKey, token));
            probe.event("release", reqId, id, "mode=compare_and_delete deleted=" + deleted
                    + " token=" + token.substring(0, 8));
        } catch (RuntimeException e) {
            //释放失败不能抹掉原请求结果；此处只记录，锁由租期回收（io.error 已记录 stage=release）
            log.warn("文章详情锁释放失败，锁将等待租期回收, lockKey={}, error={}", lockKey, e.getMessage());
        }
    }

    /**
     * 单次详情请求的结果载体，用于统一打点。
     * {@code dbSelect} 只统计本请求真正发起的 DAO 调用：getById 计 1，正文查询计 1；
     * 因此未查到文章为 1，命中并取到正文为 2，纯缓存命中为 0。
     */
    private static final class DetailCall {
        private final ResponseResult response;
        private final String result;
        private final int dbSelect;

        private DetailCall(ResponseResult response, String result, int dbSelect) {
            this.response = response;
            this.result = result;
            this.dbSelect = dbSelect;
        }
    }

    /**
     * 从缓存字符串还原详情。返回 null 表示缓存内容不可用（脏数据），调用方按未命中处理。
     */
    private DetailCall fromDetailCache(String cached) {
        if (NULL_CACHE_VALUE.equals(cached)) {
            return new DetailCall(ResponseResult.errorResult(AppHttpCodeEnum.DATA_NOT_EXIST), "NULL_HIT", 0);
        }
        try {
            ArticleDetailVo vo = objectMapper.readValue(cached, ArticleDetailVo.class);
            return new DetailCall(ResponseResult.okResult(vo), "HIT", 0);
        } catch (Exception e) {
            log.warn("文章详情缓存反序列化失败: {}", e.getMessage());
            return null;
        }
    }

    private DetailCall queryArticleDetail(Long id, String cacheKey, boolean writeCache, long reqId) {
        long attemptId = DB_ATTEMPT_SEQ.incrementAndGet();
        long dbDelay = probe.dbDelayMillis(id);
        //rebuild.*: 整个「重建」区间（含模拟延迟），用于请求级对账
        probe.event("rebuild.begin", reqId, id, "attemptId=" + attemptId + " simulatedDelayMs=" + dbDelay
                + " writeCache=" + writeCache);
        try {
            if (dbDelay > 0) {
                //R2：模拟延迟单独成段，不混进实际 DAO 区间，避免把睡眠当成 DB 执行时间
                probe.event("db.delay.begin", reqId, id, "attemptId=" + attemptId + " delayMs=" + dbDelay);
                probe.sleep(dbDelay);
                probe.event("db.delay.end", reqId, id, "attemptId=" + attemptId);
            }
            //db.enter/db.exit 只包住真正的 DAO 调用
            probe.event("db.enter", reqId, id, "attemptId=" + attemptId + " writeCache=" + writeCache);
            try {
                return doQueryArticleDetail(id, cacheKey, writeCache, reqId, attemptId);
            } catch (RuntimeException e) {
                probe.event("db.error", reqId, id, "attemptId=" + attemptId + " error=" + e.getClass().getSimpleName());
                throw e;
            } finally {
                probe.event("db.exit", reqId, id, "attemptId=" + attemptId);
            }
        } finally {
            //延迟/DAO 任一环节出错都留退出记录
            probe.event("rebuild.exit", reqId, id, "attemptId=" + attemptId);
        }
    }

    private DetailCall doQueryArticleDetail(Long id, String cacheKey, boolean writeCache, long reqId, long attemptId) {
        //P1.3a：文章 + 正文两次查询收缩到一个**短只读事务**里，读到同一个一致性快照。
        //事务只覆盖这两条 SELECT，方法返回后连接立即归还；VO 组装、序列化与回填 Redis 都在事务之外，
        //因此详情回源不会因为缓存命中/争锁/等待而长期占着连接。
        long snapshotStart = System.nanoTime();
        probe.event("db.snapshot.begin", reqId, id, "attemptId=" + attemptId + " readOnlyTransaction=true");
        ArticleDetailSnapshotReader.Snapshot snapshot = articleDetailSnapshotReader.load(id);
        probe.event("db.snapshot.end", reqId, id, "attemptId=" + attemptId
                + " elapsedMs=" + ((System.nanoTime() - snapshotStart) / 1_000_000L)
                + " found=" + (snapshot.getArticle() != null));
        ApArticle article = snapshot.getArticle();
        if (article == null) {
            //空值缓存：拦住对不存在 ID 的重复查询
            if (writeCache) {
                probe.delayCacheWrite(id, reqId);
                probe.event("cache.write.begin", reqId, id, "attemptId=" + attemptId + " value=__NULL__");
                cacheService.setEx(cacheKey, NULL_CACHE_VALUE, articleDetailNullExpireSeconds, TimeUnit.SECONDS);
                probe.event("cache.write.done", reqId, id, "attemptId=" + attemptId + " value=__NULL__");
            }
            return new DetailCall(ResponseResult.errorResult(AppHttpCodeEnum.DATA_NOT_EXIST), "DB_MISS", 1);
        }

        ApArticleContent content = snapshot.getContent();

        ArticleDetailVo vo = new ArticleDetailVo();
        vo.setArticle(article);
        vo.setContent(content == null ? "" : content.getContent());

        if (writeCache) {
            //TTL 加随机抖动，避免大量 key 同时过期；抖动为 0 时得到确定 TTL（功能试验用）
            long jitter = articleDetailExpireJitterSeconds > 0
                    ? ThreadLocalRandom.current().nextLong(articleDetailExpireJitterSeconds)
                    : 0L;
            long expire = articleDetailExpireSeconds + jitter;
            //P1.3a 夹具：把回填推到提交之后的不同时间点（默认 0，正常路径不受影响）
            probe.delayCacheWrite(id, reqId);
            probe.event("cache.write.begin", reqId, id, "attemptId=" + attemptId + " expireSeconds=" + expire);
            try {
                //与 HTTP 响应使用同一个 ObjectMapper，保证缓存里的 JSON 与响应体同构
                cacheService.setEx(cacheKey, objectMapper.writeValueAsString(vo), expire, TimeUnit.SECONDS);
                probe.event("cache.write.done", reqId, id, "attemptId=" + attemptId);
            } catch (Exception e) {
                //写缓存失败不影响本次响应，但必须留痕，不能静默
                probe.event("cache.write.fail", reqId, id, "error=" + e.getClass().getSimpleName());
                log.warn("文章详情写入缓存失败, articleId={}, error={}", id, e.getMessage());
            }
        }
        return new DetailCall(ResponseResult.okResult(vo), "DB_HIT", 2);
    }

    /**
     * 详情读路径的结构化打点，用于按请求统计命中/回源/锁行为。
     * 只输出一行，便于从日志按 reqId 归属到具体请求，不依赖 Redis 全局 info。
     */
    private void logDetailMetric(long reqId, Long id, String mode, String result,
                                 String lock, int dbSelect, long startNanos) {
        long costMs = (System.nanoTime() - startNanos) / 1_000_000L;
        log.info("[DETAIL-METRIC] reqId={} articleId={} mode={} result={} lock={} dbSelect={} costMs={}",
                reqId, id, mode, result, lock, dbSelect, costMs);
    }

    /**
     * 更新文章的分值  同时更新缓存中的热点文章数据
     * @param mess
     */
    @Override
    public void updateScore(ArticleVisitStreamMess mess) {
        //1.更新文章的阅读、点赞、收藏、评论的数量
        ApArticle apArticle = updateArticle(mess);
        //P1.3b：行为计数已经通过 updateArticle -> updateById 真实写库。失效在这里**登记**，
        //由 updateScore 自己的事务成功提交后执行；回滚不执行。热门榜单行为不变。
        probe.event("behavior_count.updated", 0L, apArticle.getId(),
                "views=" + apArticle.getViews() + " likes=" + apArticle.getLikes()
                        + " comments=" + apArticle.getComment() + " collections=" + apArticle.getCollection());
        detailCacheInvalidator.invalidateAfterWrite(apArticle.getId(), "updateScore:afterUpdate");
        //P1.3b 夹具（默认关闭）：登记后受控回滚，用于证明回滚不删缓存、DB 计数不增
        if (probe.rollbackBehaviorCountConfiguredFor(apArticle.getId())) {
            probe.event("p13b.controlled_rollback", 0L, apArticle.getId(), "phase=after_register_updateScore");
            throw new IllegalStateException("P1.3b controlled rollback of the behaviour count write");
        }
        //2.计算文章的分值
        Integer score = computeScore(apArticle);
        score = score * 3;

        //3.替换当前文章对应频道的热点数据
        replaceDataToRedis(apArticle, score, ArticleConstants.HOT_ARTICLE_FIRST_PAGE + apArticle.getChannelId());

        //4.替换推荐对应的热点数据
        replaceDataToRedis(apArticle, score, ArticleConstants.HOT_ARTICLE_FIRST_PAGE + ArticleConstants.DEFAULT_TAG);

    }

    /**
     * 替换数据并且存入到redis
     * @param apArticle
     * @param score
     * @param s
     */
    private void replaceDataToRedis(ApArticle apArticle, Integer score, String s) {
        String articleListStr = cacheService.get(s);
        if (StringUtils.isNotBlank(articleListStr)) {
            List<HotArticleVo> hotArticleVoList = JSON.parseArray(articleListStr, HotArticleVo.class);

            boolean flag = true;

            //如果缓存中存在该文章，只更新分值
            for (HotArticleVo hotArticleVo : hotArticleVoList) {
                if (hotArticleVo.getId().equals(apArticle.getId())) {
                    hotArticleVo.setScore(score);
                    flag = false;
                    break;
                }
            }

            //如果缓存中不存在，查询缓存中分值最小的一条数据，进行分值的比较，如果当前文章的分值大于缓存中的数据，就替换
            if (flag) {
                if (hotArticleVoList.size() >= 30) {
                    hotArticleVoList = hotArticleVoList.stream().sorted(Comparator.comparing(HotArticleVo::getScore).reversed()).collect(Collectors.toList());
                    HotArticleVo lastHot = hotArticleVoList.get(hotArticleVoList.size() - 1);
                    if (lastHot.getScore() < score) {
                        hotArticleVoList.remove(lastHot);
                        HotArticleVo hot = new HotArticleVo();
                        BeanUtils.copyProperties(apArticle, hot);
                        hot.setScore(score);
                        hotArticleVoList.add(hot);
                    }


                } else {
                    HotArticleVo hot = new HotArticleVo();
                    BeanUtils.copyProperties(apArticle, hot);
                    hot.setScore(score);
                    hotArticleVoList.add(hot);
                }
            }
            //缓存到redis
            hotArticleVoList = hotArticleVoList.stream().sorted(Comparator.comparing(HotArticleVo::getScore).reversed()).collect(Collectors.toList());
            cacheService.set(s, JSON.toJSONString(hotArticleVoList));

        }
    }

    /**
     * 更新文章行为数量
     * @param mess
     */
    private ApArticle updateArticle(ArticleVisitStreamMess mess) {
        ApArticle apArticle = getById(mess.getArticleId());
        apArticle.setCollection(apArticle.getCollection()==null?0:apArticle.getCollection()+mess.getCollect());
        apArticle.setComment(apArticle.getComment()==null?0:apArticle.getComment()+mess.getComment());
        apArticle.setLikes(apArticle.getLikes()==null?0:apArticle.getLikes()+mess.getLike());
        apArticle.setViews(apArticle.getViews()==null?0:apArticle.getViews()+mess.getView());
        updateById(apArticle);
        return apArticle;

    }

    /**
     * 计算文章的具体分值
     * @param apArticle
     * @return
     */
    private Integer computeScore(ApArticle apArticle) {
        Integer score = 0;
        if(apArticle.getLikes() != null){
            score += apArticle.getLikes() * ArticleConstants.HOT_ARTICLE_LIKE_WEIGHT;
        }
        if(apArticle.getViews() != null){
            score += apArticle.getViews();
        }
        if(apArticle.getComment() != null){
            score += apArticle.getComment() * ArticleConstants.HOT_ARTICLE_COMMENT_WEIGHT;
        }
        if(apArticle.getCollection() != null){
            score += apArticle.getCollection() * ArticleConstants.HOT_ARTICLE_COLLECTION_WEIGHT;
        }

        return score;
    }

    /**
     * 图文统计统计
     * @param wmUserId
     * @param beginDate
     * @param endDate
     * @return
     */
    @Override
    public ResponseResult queryLikesAndConllections(Integer wmUserId, Date beginDate, Date endDate) {
        Map map = apArticleMapper.queryLikesAndConllections(wmUserId, beginDate, endDate);
        return ResponseResult.okResult(map);
    }

    /**
     * 分页查询 图文统计
     * @param dto
     * @return
     */
    @Override
    public PageResponseResult newPage(StatisticsDto dto) {

        //类型转换
        Date beginDate = DateUtils.stringToDate(dto.getBeginDate());
        Date endDate = DateUtils.stringToDate(dto.getEndDate());
        //检查参数
        dto.checkParam();
        //分页查询
        IPage page = new Page(dto.getPage(), dto.getSize());
        LambdaQueryWrapper<ApArticle> lambdaQueryWrapper = Wrappers.<ApArticle>lambdaQuery()
                .eq(ApArticle::getAuthorId, dto.getWmUserId())
                .between(ApArticle::getPublishTime,beginDate, endDate)
                .select(ApArticle::getId,ApArticle::getTitle,ApArticle::getLikes,ApArticle::getCollection,ApArticle::getComment,ApArticle::getViews);

        lambdaQueryWrapper.orderByDesc(ApArticle::getPublishTime);

        page = page(page,lambdaQueryWrapper);

        PageResponseResult responseResult = new PageResponseResult(dto.getPage(),dto.getSize(),(int)page.getTotal());
        responseResult.setData(page.getRecords());

        return responseResult;
    }

    /**
     * 查询文章评论统计
     * @param dto
     * @return
     */
    @Override
    public PageResponseResult findNewsComments(ArticleCommentDto dto) {

        Integer currentPage = dto.getPage();
        dto.setPage((dto.getPage()-1)*dto.getSize());
        List<ArticleCommnetVo> list = apArticleMapper.findNewsComments(dto);
        int count = apArticleMapper.findNewsCommentsCount(dto);

        PageResponseResult responseResult = new PageResponseResult(currentPage,dto.getSize(),count);
        responseResult.setData(list);
        return responseResult;
    }


}