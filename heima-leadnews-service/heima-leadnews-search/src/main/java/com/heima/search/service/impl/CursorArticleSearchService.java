package com.heima.search.service.impl;
import com.alibaba.fastjson.JSON;
import com.heima.model.search.dtos.CursorSearchDto;
import com.heima.model.user.pojos.ApUser;
import com.heima.search.service.ApUserSearchService;
import com.heima.search.support.SearchCursor;
import com.heima.utils.thread.AppThreadLocalUtil;
import org.elasticsearch.action.search.*;
import org.elasticsearch.client.*;
import org.elasticsearch.common.text.Text;
import org.elasticsearch.index.query.*;
import org.elasticsearch.search.SearchHit;
import org.elasticsearch.search.builder.SearchSourceBuilder;
import org.elasticsearch.search.fetch.subphase.highlight.*;
import org.elasticsearch.search.sort.SortOrder;
import org.springframework.beans.factory.annotation.*;
import org.springframework.stereotype.Service;
import java.io.IOException;
import java.util.*;

@Service
public class CursorArticleSearchService {
    @Autowired private RestHighLevelClient client;
    @Autowired private ApUserSearchService history;
    @Value("${leadnews.search.query.index:app_info_article}") private String index="app_info_article";
    public Map<String,Object> search(CursorSearchDto dto) throws IOException {
        if(dto==null||dto.getSearchWords()==null||dto.getSearchWords().trim().isEmpty()||dto.getSearchWords().length()>200)
            throw new IllegalArgumentException("searchWords must contain 1..200 characters");
        String query=dto.getSearchWords().trim();int size=dto.getPageSize()==null?10:dto.getPageSize();
        if(size<1||size>50)throw new IllegalArgumentException("pageSize must be 1..50");
        SearchCursor cursor=null;long bound;
        if(dto.getCursor()!=null) {
            cursor=SearchCursor.decode(dto.getCursor(),query);bound=cursor.upperBound;
            if(dto.getUpperBoundMillis()!=null && dto.getUpperBoundMillis()!=bound)throw new IllegalArgumentException("Cursor boundary changed");
        }else {
            long now=System.currentTimeMillis();bound=dto.getUpperBoundMillis()==null?now:dto.getUpperBoundMillis();
            if(bound<=0||bound>now)throw new IllegalArgumentException("Invalid first-page boundary");
        }
        ApUser user=AppThreadLocalUtil.getUser();
        if(cursor==null&&user!=null)history.insert(query,user.getId());
        SearchSourceBuilder source=source(query,bound,size+1);
        if(cursor!=null)source.searchAfter(new Object[]{cursor.lastTime,cursor.lastId});
        SearchResponse response=client.search(new SearchRequest(index).source(source),RequestOptions.DEFAULT);
        SearchHit[] hits=response.getHits().getHits();boolean hasMore=hits.length>size;
        List<Map<String,Object>>items=new ArrayList<>();
        for(int i=0;i<Math.min(size,hits.length);i++)items.add(item(hits[i]));
        String next=null;
        if(hasMore&&!items.isEmpty()){
            Object[]sort=hits[items.size()-1].getSortValues();
            next=new SearchCursor(bound,SearchCursor.exactLong(sort[0]),SearchCursor.exactLong(sort[1])).encode(query);
        }
        Map<String,Object>out=new LinkedHashMap<>();out.put("items",items);out.put("hasMore",hasMore);out.put("nextCursor",next);
        out.put("upperBoundMillis",bound);out.put("tookMs",response.getTook().millis());return out;
    }
    /** Shared query shape also used by the explicitly experimental offset comparator. */
    public static SearchSourceBuilder source(String query,long bound,int size) {
        BoolQueryBuilder q=QueryBuilders.boolQuery().must(QueryBuilders.queryStringQuery(query).field("title").field("content").defaultOperator(Operator.OR))
                .filter(QueryBuilders.rangeQuery("publishTime").lt(bound)).filter(QueryBuilders.existsQuery("publishTime")).filter(QueryBuilders.existsQuery("id"));
        HighlightBuilder highlight=new HighlightBuilder().field("title").preTags("<font style='color: red; font-size: inherit;'>").postTags("</font>");
        return new SearchSourceBuilder().query(q).size(size).sort("publishTime",SortOrder.DESC).sort("id",SortOrder.DESC).highlighter(highlight).trackTotalHits(false);
    }
    public static Map<String,Object> item(SearchHit hit) {
        Map<String,Object>m=JSON.parseObject(hit.getSourceAsString());
        Object[]sort=hit.getSortValues();m.put("id",Long.toString(SearchCursor.exactLong(sort[1])));
        HighlightField title=hit.getHighlightFields()==null?null:hit.getHighlightFields().get("title");
        String value=String.valueOf(m.get("title"));
        if(title!=null&&title.getFragments()!=null&&title.getFragments().length>0){StringBuilder b=new StringBuilder();for(Text x:title.getFragments())b.append(x.string());value=b.toString();}
        m.put("h_title",value);return m;
    }
}
