package com.heima.search.support;
import com.alibaba.fastjson.JSON;
import com.alibaba.fastjson.JSONObject;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.Base64;
import java.util.LinkedHashMap;
import java.util.Map;

/** Opaque continuation state, not an authorization token or ES point-in-time snapshot. */
public final class SearchCursor {
    public static final String SORT = "publishTime:desc,id:desc";
    public final long upperBound, lastTime, lastId;
    public SearchCursor(long bound,long time,long id) {
        if(bound<=0||time<0||time>=bound||id<=0)throw new IllegalArgumentException("Invalid cursor range");
        upperBound=bound;lastTime=time;lastId=id;
    }
    public String encode(String query) {
        Map<String,Object> m=new LinkedHashMap<>();
        m.put("v",1);m.put("q",fingerprint(query));m.put("sort",SORT);
        m.put("upper",upperBound);m.put("time",lastTime);m.put("id",Long.toString(lastId));
        return Base64.getUrlEncoder().withoutPadding().encodeToString(JSON.toJSONString(m).getBytes(StandardCharsets.UTF_8));
    }
    public static SearchCursor decode(String token,String query) {
        try {
            if(token==null||token.length()>2048||!token.matches("[A-Za-z0-9_-]+"))throw new IllegalArgumentException();
            byte[] bytes=Base64.getUrlDecoder().decode(token);
            JSONObject m=JSON.parseObject(new String(bytes,StandardCharsets.UTF_8));
            if(m==null||m.size()!=6||!(m.get("v") instanceof Integer)||m.getIntValue("v")!=1
                    ||!SORT.equals(m.get("sort"))||!fingerprint(query).equals(m.get("q")))throw new IllegalArgumentException();
            Object id=m.get("id");
            if(!(id instanceof String)||!((String)id).matches("[1-9][0-9]{0,18}"))throw new IllegalArgumentException();
            return new SearchCursor(exactLong(m.get("upper")),exactLong(m.get("time")),Long.parseLong((String)id));
        } catch(RuntimeException e) {throw new IllegalArgumentException("Invalid cursor or changed query",e);}
    }
    public static long exactLong(Object v) {
        if(!(v instanceof Integer)&&!(v instanceof Long))throw new IllegalArgumentException("Integer sort value required");
        return ((Number)v).longValue();
    }
    private static String fingerprint(String q) {
        try {
            byte[] bytes=MessageDigest.getInstance("SHA-256").digest((q+"\n"+SORT).getBytes(StandardCharsets.UTF_8));
            StringBuilder s=new StringBuilder();for(byte b:bytes)s.append(String.format("%02x",b&255));return s.toString();
        }catch(java.security.NoSuchAlgorithmException e){throw new IllegalStateException(e);}
    }
}
