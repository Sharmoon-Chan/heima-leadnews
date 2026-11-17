import org.apache.kafka.clients.producer.KafkaProducer
import org.apache.kafka.clients.producer.ProducerRecord
import org.apache.kafka.common.header.internals.RecordHeader
import groovy.json.JsonOutput
import java.util.concurrent.TimeUnit

def producer = vars.getObject('producer')
if(producer == null) {
    Properties p = new Properties()
    p.put('bootstrap.servers', props.getProperty('p23.broker','192.168.200.130:9092'))
    p.put('key.serializer','org.apache.kafka.common.serialization.StringSerializer')
    p.put('value.serializer','org.apache.kafka.common.serialization.StringSerializer')
    p.put('acks','all'); p.put('enable.idempotence','true')
    p.put('retries','10'); p.put('max.in.flight.requests.per.connection','5')
    p.put('max.block.ms','5000');p.put('request.timeout.ms','3000');p.put('delivery.timeout.ms','10000')
    producer = new KafkaProducer<String,String>(p)
    vars.putObject('producer',producer)
}
long seq = (vars.get('seq') ?: '0').toLong() + 1
vars.put('seq', Long.toString(seq))
String run = props.getProperty('p23.run')
String id = Long.toString(props.getProperty('p23.idbase').toLong() + seq)
String event = run + '-' + seq
long now = System.currentTimeMillis()
def payload=[id:id,title:event,content:'P23 fixed payload '+('x'*512),authorId:1009,publishTime:1794100000000]
def body=JsonOutput.toJson([schemaVersion:1,eventId:event,articleId:id,occurredAt:now,payload:payload])
def record=new ProducerRecord<String,String>(props.getProperty('p23.topic'), (int)(seq%4),id,body)
record.headers().add(new RecordHeader('eventId',event.getBytes('UTF-8')))
def md=producer.send(record).get(12,TimeUnit.SECONDS)
vars.put('event_id',event);vars.put('article_id',id)
vars.put('partition',Integer.toString(md.partition()));vars.put('offset',Long.toString(md.offset()))
SampleResult.setSuccessful(true);SampleResult.setResponseCode('200')
SampleResult.setResponseMessage('broker acknowledged')
SampleResult.setResponseData('', 'UTF-8')
