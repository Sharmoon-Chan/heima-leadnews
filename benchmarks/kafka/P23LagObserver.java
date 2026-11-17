import com.alibaba.fastjson.JSON;
import org.apache.kafka.clients.admin.*;
import org.apache.kafka.clients.consumer.OffsetAndMetadata;
import org.apache.kafka.common.TopicPartition;
import java.util.*;
import java.nio.file.*;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.TimeUnit;
/** Native AdminClient read-only lag snapshots, not a message scheduler. */
public class P23LagObserver{
 public static void main(String[]args)throws Exception{
  String group=args[0],topic=args[1];int seconds=Integer.parseInt(args[2]);Path output=Paths.get(args[3]);
  if(!topic.startsWith("p23-20261108-")||!group.startsWith("p23-20261108-"))throw new IllegalArgumentException("isolated scope");
  Files.createFile(output);Properties p=new Properties();p.put("bootstrap.servers","192.168.200.130:9092");p.put("request.timeout.ms","3000");p.put("default.api.timeout.ms","4000");
  try(AdminClient c=AdminClient.create(p)){
   TopicDescription td=c.describeTopics(Collections.singleton(topic)).all().get(5,TimeUnit.SECONDS).get(topic);
   Map<TopicPartition,OffsetSpec>req=new HashMap<>();td.partitions().forEach(x->req.put(new TopicPartition(topic,x.partition()),OffsetSpec.latest()));
   long deadline=System.currentTimeMillis()+seconds*1000L;
   while(System.currentTimeMillis()<deadline){
    long now=System.currentTimeMillis();Map<String,Object>row=new LinkedHashMap<>();row.put("epoch_ms",now);
    try{
     Map<TopicPartition,ListOffsetsResult.ListOffsetsResultInfo>ends=c.listOffsets(req).all().get(5,TimeUnit.SECONDS);
     Map<TopicPartition,OffsetAndMetadata>commits=c.listConsumerGroupOffsets(group).partitionsToOffsetAndMetadata().get(5,TimeUnit.SECONDS);
     long total=0,end=0,committed=0;
     for(TopicPartition tp:req.keySet()){long e=ends.get(tp).offset(),m=commits.containsKey(tp)?commits.get(tp).offset():0;end+=e;committed+=m;total+=Math.max(0,e-m);}
     row.put("end",end);row.put("committed",committed);row.put("lag",total);
    }catch(Exception e){row.put("error",e.getClass().getSimpleName());}
    Files.write(output,(JSON.toJSONString(row)+"\n").getBytes(StandardCharsets.UTF_8),StandardOpenOption.APPEND);
    long wait=1000-(System.currentTimeMillis()-now);if(wait>0)Thread.sleep(wait);
   }
  }
 }
}
