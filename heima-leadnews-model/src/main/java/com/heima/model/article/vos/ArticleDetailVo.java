package com.heima.model.article.vos;

import com.heima.model.article.pojos.ApArticle;
import lombok.Data;

import java.io.Serializable;

/**
 * 文章详情响应体。
 *
 * <p>为什么需要这个 VO（CACHE-006 响应契约）：
 * 详情接口的返回结构是 {@code {"article":{...},"content":"..."}}，原先冷读（回源）用 {@code Map+ApArticle POJO}
 * 组装、热读（缓存）用 fastjson 解析成 {@code JSONObject}。项目的 {@code ConfusionModule} 会把 POJO 里名为
 * {@code id} 的属性序列化成字符串，而 Map/JSONObject 里的数字不会经过这一层，于是同一个接口
 * 冷热两次响应中 {@code id} 分别是字符串和数字；文章 ID 是 19 位 Long（大于 2^53-1），
 * 前端按 double 解析会丢精度。冷热两条路径统一使用本类 + 同一个 Jackson ObjectMapper 后，
 * ID 类型与 null/缺省策略就一致了。</p>
 */
@Data
public class ArticleDetailVo implements Serializable {

    private static final long serialVersionUID = 1L;

    /** 文章主体 */
    private ApArticle article;

    /** 文章正文，无正文时为空串（与历史行为保持一致，不使用 null） */
    private String content;
}
