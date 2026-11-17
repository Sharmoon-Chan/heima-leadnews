package com.heima.search.support;
import com.alibaba.fastjson.JSON;
import com.alibaba.fastjson.JSONObject;
import org.junit.jupiter.api.Test;
import java.nio.charset.StandardCharsets;
import java.util.Base64;
import static org.junit.jupiter.api.Assertions.*;
class SearchCursorTest {
 @Test void roundTripPreservesLargeLongAndBoundary(){
  SearchCursor original=new SearchCursor(1790000001000L,1790000000000L,950800000000001034L);
  SearchCursor actual=SearchCursor.decode(original.encode("p3match"),"p3match");
  assertEquals(original.lastId,actual.lastId);assertEquals(original.lastTime,actual.lastTime);assertEquals(original.upperBound,actual.upperBound);
 }
 @Test void rejectsMalformedAndChangedQuery(){
  String token=new SearchCursor(10000,9000,9007199254740993L).encode("a");
  assertThrows(IllegalArgumentException.class,()->SearchCursor.decode(token,"b"));
  for(String bad:new String[]{"","%%%","a",new String(new char[2049]).replace('\0','a')})
   assertThrows(IllegalArgumentException.class,()->SearchCursor.decode(bad,"a"));
 }
 @Test void rejectsUnsupportedTypesBoundsAndSorting(){
  String token=new SearchCursor(10000,9000,9007199254740993L).encode("a");
  JSONObject base=JSON.parseObject(new String(Base64.getUrlDecoder().decode(token),StandardCharsets.UTF_8));
  Object[][]cases={{"v",2},{"sort","id:asc"},{"id",9007199254740993L},{"id","9223372036854775808"},{"time",10000},{"time",9.2},{"upper",0}};
  for(Object[]c:cases){JSONObject changed=JSON.parseObject(base.toJSONString());changed.put((String)c[0],c[1]);String bad=Base64.getUrlEncoder().withoutPadding().encodeToString(changed.toJSONString().getBytes(StandardCharsets.UTF_8));assertThrows(IllegalArgumentException.class,()->SearchCursor.decode(bad,"a"));}
 }
}
