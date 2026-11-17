package com.heima.search.controller.v1;
import com.heima.model.common.dtos.ResponseResult;
import com.heima.model.common.enums.AppHttpCodeEnum;
import com.heima.model.search.dtos.CursorSearchDto;
import com.heima.search.service.impl.CursorArticleSearchService;
import org.elasticsearch.ElasticsearchStatusException;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.web.bind.annotation.*;
import java.io.IOException;
@RestController
@RequestMapping("/api/v1/article/search")
public class ArticleCursorController {
 @Autowired private CursorArticleSearchService service;
 @PostMapping("/cursor")
 public ResponseResult search(@RequestBody CursorSearchDto dto)throws IOException {
  try{return ResponseResult.okResult(service.search(dto));}
  catch(IllegalArgumentException e){return ResponseResult.errorResult(AppHttpCodeEnum.PARAM_INVALID,e.getMessage());}
  catch(ElasticsearchStatusException e){if(e.status().getStatus()==400)return ResponseResult.errorResult(AppHttpCodeEnum.PARAM_INVALID,"Invalid search query");throw e;}
 }
}
