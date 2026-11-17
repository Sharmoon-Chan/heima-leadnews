-- P0 最小链路 DDL：仅覆盖 article 详情 API 读取所需表。
-- 来源：从 heima-leadnews-model 的 ApArticle / ApArticleContent / ApArticleConfig
-- 实体注解与 ApArticleMapper.xml 字段反推。仓库内没有课程原始 SQL 文件，
-- 因此本文件是"重建的最小 schema"，不是生产/课程原始 DDL，字段长度与索引仅为本地实验选择。
-- 数据库名通过 MYSQL_DATABASE 指定（默认 leadnews），本文件不切换库。

CREATE TABLE IF NOT EXISTS `ap_article` (
  `id` bigint(20) NOT NULL COMMENT '主键',
  `title` varchar(200) NOT NULL DEFAULT '' COMMENT '标题',
  `author_id` bigint(20) DEFAULT NULL COMMENT '作者id',
  `author_name` varchar(50) DEFAULT NULL COMMENT '作者名称',
  `channel_id` int(11) DEFAULT NULL COMMENT '频道id',
  `channel_name` varchar(50) DEFAULT NULL COMMENT '频道名称',
  `layout` tinyint(4) DEFAULT NULL COMMENT '布局 0无图 1单图 2多图',
  `flag` tinyint(4) DEFAULT NULL COMMENT '标记 0普通 1热点 2置顶 3精品 4大V',
  `images` varchar(1024) DEFAULT NULL COMMENT '封面图片',
  `labels` varchar(255) DEFAULT NULL COMMENT '标签',
  `likes` int(11) NOT NULL DEFAULT '0' COMMENT '点赞数',
  `collection` int(11) NOT NULL DEFAULT '0' COMMENT '收藏数',
  `comment` int(11) NOT NULL DEFAULT '0' COMMENT '评论数',
  `views` int(11) NOT NULL DEFAULT '0' COMMENT '阅读数',
  `province_id` int(11) DEFAULT NULL,
  `city_id` int(11) DEFAULT NULL,
  `county_id` int(11) DEFAULT NULL,
  `created_time` datetime DEFAULT NULL COMMENT '创建时间',
  `publish_time` datetime DEFAULT NULL COMMENT '发布时间',
  `sync_status` tinyint(1) NOT NULL DEFAULT '0' COMMENT '同步状态',
  `origin` tinyint(1) NOT NULL DEFAULT '1' COMMENT '来源',
  `static_url` varchar(255) DEFAULT NULL COMMENT '静态页地址',
  PRIMARY KEY (`id`),
  KEY `idx_publish_time` (`publish_time`),
  KEY `idx_channel_publish` (`channel_id`, `publish_time`),
  KEY `idx_author_id` (`author_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='APP已发布文章';

CREATE TABLE IF NOT EXISTS `ap_article_content` (
  `id` bigint(20) NOT NULL,
  `article_id` bigint(20) DEFAULT NULL COMMENT '文章id',
  `content` longtext COMMENT '文章内容',
  PRIMARY KEY (`id`),
  UNIQUE KEY `uk_article_id` (`article_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='APP已发布文章内容';

CREATE TABLE IF NOT EXISTS `ap_article_config` (
  `id` bigint(20) NOT NULL,
  `article_id` bigint(20) DEFAULT NULL COMMENT '文章id',
  `is_comment` tinyint(1) DEFAULT '1' COMMENT '是否可评论',
  `is_forward` tinyint(1) DEFAULT '1' COMMENT '是否可转发',
  `is_down` tinyint(1) DEFAULT '0' COMMENT '是否下架',
  `is_delete` tinyint(1) DEFAULT '0' COMMENT '是否删除',
  PRIMARY KEY (`id`),
  UNIQUE KEY `uk_article_id` (`article_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='APP已发布文章配置';
