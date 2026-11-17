import com.alibaba.fastjson.JSON;
import org.apache.kafka.clients.admin.*;
import org.apache.kafka.clients.consumer.*;
import org.apache.kafka.clients.producer.*;
import org.apache.kafka.common.*;
import org.apache.kafka.common.config.ConfigResource;
import org.apache.kafka.common.header.Header;
import org.apache.kafka.common.header.internals.RecordHeader;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.time.Duration;
import java.util.*;
import java.util.concurrent.TimeUnit;

/** Small finite P2.1 scenario helper using official clients; no workload generator. */
public class P23ScenarioCli {
    static final String BROKER = "192.168.200.130:9092";
    static Properties base() { Properties p=new Properties(); p.put("bootstrap.servers",BROKER);p.put("request.timeout.ms","5000");p.put("default.api.timeout.ms","10000");return p; }
    static void emit(Object x){System.out.println("RESULT "+JSON.toJSONString(x));}
    static Map<String,Object> m(Object... values){Map<String,Object> m=new LinkedHashMap<>();for(int i=0;i<values.length;i+=2)m.put((String)values[i],values[i+1]);return m;}
    static void scope(String topic){if(!topic.startsWith("p23-20261108-"))throw new IllegalArgumentException("test topic prefix required");}
    public static void main(String[] a) throws Exception {
        if(a.length<2)throw new IllegalArgumentException("command + topic/group required");
        switch(a[0]) {
        case "totals": {
            List<String>topics=new ArrayList<>();for(int i=1;i<a.length;i++){scope(a[i]);topics.add(a[i]);}
            try(AdminClient c=AdminClient.create(base())){
                Map<String,TopicDescription>desc=c.describeTopics(topics).all().get(10,TimeUnit.SECONDS);
                Map<TopicPartition,OffsetSpec>req=new HashMap<>();
                for(TopicDescription t:desc.values())t.partitions().forEach(x->req.put(new TopicPartition(t.name(),x.partition()),OffsetSpec.latest()));
                Map<TopicPartition,ListOffsetsResult.ListOffsetsResultInfo>ends=c.listOffsets(req).all().get(10,TimeUnit.SECONDS);
                Map<String,Long>out=new TreeMap<>();for(Map.Entry<TopicPartition,ListOffsetsResult.ListOffsetsResultInfo>e:ends.entrySet())out.merge(e.getKey().topic(),e.getValue().offset(),Long::sum);
                emit(out);
            }break;
        }
        case "create": {
            scope(a[1]); int count=Integer.parseInt(a[2]);
            try(AdminClient c=AdminClient.create(base())) {
                NewTopic t=new NewTopic(a[1],count,(short)1); t.configs(Collections.singletonMap("retention.ms","604800000"));
                c.createTopics(Collections.singleton(t)).all().get(15,TimeUnit.SECONDS);
                TopicDescription d=c.describeTopics(Collections.singleton(a[1])).all().get(10,TimeUnit.SECONDS).get(a[1]);
                emit(m("created",d.name(),"partitions",d.partitions().size(),"replicas",d.partitions().get(0).replicas().size()));
            } break; }
        case "send": {
            scope(a[1]);int partition=Integer.parseInt(a[2]);String event=a[3];byte[] body=Files.readAllBytes(Paths.get(a[4]));
            Properties p=base();p.put("key.serializer","org.apache.kafka.common.serialization.StringSerializer");p.put("value.serializer","org.apache.kafka.common.serialization.ByteArraySerializer");
            p.put("acks","all");p.put("enable.idempotence","true");p.put("retries","10");p.put("max.in.flight.requests.per.connection","5");p.put("delivery.timeout.ms","12000");p.put("max.block.ms","10000");
            try(KafkaProducer<String,byte[]> c=new KafkaProducer<>(p)) {
                ProducerRecord<String,byte[]> r=new ProducerRecord<>(a[1],partition,event,body);
                r.headers().add(new RecordHeader("eventId",event.getBytes(StandardCharsets.UTF_8)));
                RecordMetadata md=c.send(r).get(15,TimeUnit.SECONDS);
                emit(m("event_id",event,"topic",md.topic(),"partition",md.partition(),"offset",md.offset(),"payload_bytes",body.length));
            } break; }
        case "batch": {
            scope(a[1]);
            java.util.List<com.alibaba.fastjson.JSONObject> specs=JSON.parseArray(new String(Files.readAllBytes(Paths.get(a[2])),StandardCharsets.UTF_8),com.alibaba.fastjson.JSONObject.class);
            if(specs.size()>100)throw new IllegalArgumentException("finite batch max100");
            Properties p=base();p.put("key.serializer","org.apache.kafka.common.serialization.StringSerializer");p.put("value.serializer","org.apache.kafka.common.serialization.ByteArraySerializer");
            p.put("acks","all");p.put("enable.idempotence","true");p.put("retries","10");p.put("max.in.flight.requests.per.connection","5");p.put("delivery.timeout.ms","12000");p.put("max.block.ms","10000");
            List<Object> sent=new ArrayList<>();
            try(KafkaProducer<String,byte[]> c=new KafkaProducer<>(p)){
                for(com.alibaba.fastjson.JSONObject x:specs){
                    String event=x.getString("eventId"),key=x.getString("key");
                    byte[] body=x.getString("value").getBytes(StandardCharsets.UTF_8);
                    ProducerRecord<String,byte[]> record=new ProducerRecord<>(a[1],x.getIntValue("partition"),key,body);
                    if(event!=null)record.headers().add(new RecordHeader("eventId",event.getBytes(StandardCharsets.UTF_8)));
                    RecordMetadata md=c.send(record).get(15,TimeUnit.SECONDS);
                    sent.add(m("event_id",event,"topic",md.topic(),"partition",md.partition(),"offset",md.offset(),"key",key,"payload_bytes",body.length));
                }
            }
            emit(m("sent",sent));break;
        }
        case "read": {
            scope(a[1]);int partition=Integer.parseInt(a[2]);long from=Long.parseLong(a[3]);int limit=Integer.parseInt(a[4]);
            Properties p=base();p.put("key.deserializer","org.apache.kafka.common.serialization.StringDeserializer");p.put("value.deserializer","org.apache.kafka.common.serialization.ByteArrayDeserializer");p.put("enable.auto.commit","false");p.put("allow.auto.create.topics","false");
            try(KafkaConsumer<String,byte[]> c=new KafkaConsumer<>(p)) {
                TopicPartition tp=new TopicPartition(a[1],partition);c.assign(Collections.singleton(tp));c.seek(tp,from);long end=c.endOffsets(Collections.singleton(tp)).get(tp);List<Object> rows=new ArrayList<>();long deadline=System.currentTimeMillis()+10000;
                while(rows.size()<limit && c.position(tp)<end && System.currentTimeMillis()<deadline) {
                    for(ConsumerRecord<String,byte[]> r:c.poll(Duration.ofMillis(500))) {
                        Map<String,List<String>> headers=new LinkedHashMap<>();
                        for(Header h:r.headers())headers.computeIfAbsent(h.key(),k->new ArrayList<>()).add(h.value()==null?null:Base64.getEncoder().encodeToString(h.value()));
                        rows.add(m("topic",r.topic(),"partition",r.partition(),"offset",r.offset(),"key",r.key(),"value",r.value()==null?null:new String(r.value(),StandardCharsets.UTF_8),"headers_base64",headers));
                        if(rows.size()>=limit)break;
                    }
                }
                emit(m("end_offset",end,"records",rows));
            } break; }
        case "offsets": {
            if(!a[1].startsWith("p23-20261108-"))throw new IllegalArgumentException("test group required");
            try(AdminClient c=AdminClient.create(base())) {
                Map<TopicPartition,OffsetAndMetadata> offsets=c.listConsumerGroupOffsets(a[1]).partitionsToOffsetAndMetadata().get(10,TimeUnit.SECONDS);
                List<Object> rows=new ArrayList<>();for(Map.Entry<TopicPartition,OffsetAndMetadata> e:offsets.entrySet())rows.add(m("topic",e.getKey().topic(),"partition",e.getKey().partition(),"offset",e.getValue().offset()));
                emit(m("group",a[1],"committed",rows));
            } break; }
        case "min-isr": {
            scope(a[1]); int value=Integer.parseInt(a[2]);
            if(value<1 || value>2)throw new IllegalArgumentException("finite min ISR test only");
            try(AdminClient c=AdminClient.create(base())) {
                ConfigResource resource=new ConfigResource(ConfigResource.Type.TOPIC,a[1]);
                Config config=new Config(Collections.singletonList(new ConfigEntry("min.insync.replicas",String.valueOf(value))));
                c.alterConfigs(Collections.singletonMap(resource,config)).all().get(10,TimeUnit.SECONDS);
                emit(m("topic",a[1],"min.insync.replicas",value));
            } break; }
        default: throw new IllegalArgumentException("unsupported command");
        }
    }
}
