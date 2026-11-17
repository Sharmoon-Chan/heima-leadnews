import com.alibaba.fastjson.JSON;
import com.alibaba.fastjson.JSONObject;
import org.apache.kafka.clients.admin.AdminClient;
import org.apache.kafka.clients.admin.TopicDescription;
import org.apache.kafka.clients.consumer.ConsumerRecord;
import org.apache.kafka.clients.consumer.KafkaConsumer;
import org.apache.kafka.clients.producer.KafkaProducer;
import org.apache.kafka.clients.producer.ProducerRecord;
import org.apache.kafka.clients.producer.RecordMetadata;
import org.apache.kafka.common.TopicPartition;
import org.apache.kafka.common.header.Header;
import org.apache.kafka.common.header.internals.RecordHeader;
import java.nio.ByteBuffer;
import java.nio.channels.FileChannel;
import java.nio.channels.FileLock;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.nio.file.StandardOpenOption;
import java.security.MessageDigest;
import java.time.Duration;
import java.time.Instant;
import java.util.*;
import java.util.concurrent.TimeUnit;

/** One explicitly selected P2.1 DLT record per invocation; dry-run unless --execute true. */
public final class P21ReplayCli {
    static final String PREFIX = "p21-20261108-";
    static final String ORIGINAL_TOPIC = "kafka_dlt-original-topic";
    static final String ORIGINAL_PARTITION = "kafka_dlt-original-partition";
    static final String ORIGINAL_OFFSET = "kafka_dlt-original-offset";

    static Map<String, Object> row(Object... args) {
        Map<String, Object> result = new LinkedHashMap<>();
        for (int i = 0; i < args.length; i += 2) result.put((String) args[i], args[i + 1]);
        return result;
    }

    static Map<String, String> options(String[] args) {
        if (args.length % 2 != 0) throw new IllegalArgumentException("Each --option requires one value");
        Set<String> allowed = new HashSet<>(Arrays.asList("bootstrap", "dlt-topic", "partition", "offset",
                "event-id", "target-topic", "confirm-target", "replay-id", "journal", "execute", "rate", "payload-sha256"));
        Map<String, String> opts = new LinkedHashMap<>();
        for (int i = 0; i < args.length; i += 2) {
            String name = args[i].startsWith("--") ? args[i].substring(2) : "";
            if (!allowed.contains(name) || opts.put(name, args[i + 1]) != null)
                throw new IllegalArgumentException("Unknown or duplicate option: " + args[i]);
        }
        return opts;
    }

    static String required(Map<String, String> opts, String name) {
        String value = opts.get(name);
        if (value == null || value.trim().isEmpty()) throw new IllegalArgumentException("Missing --" + name);
        return value;
    }

    static Properties base(String bootstrap) {
        Properties p = new Properties();
        p.put("bootstrap.servers", bootstrap);
        p.put("request.timeout.ms", "5000");
        p.put("default.api.timeout.ms", "10000");
        return p;
    }

    static byte[] header(ConsumerRecord<byte[], byte[]> record, String name) {
        byte[] value = null;
        for (Header h : record.headers().headers(name)) {
            if (h.value() == null || (value != null && !Arrays.equals(value, h.value())))
                throw new IllegalArgumentException("Missing/conflicting header: " + name);
            value = h.value();
        }
        if (value == null) throw new IllegalArgumentException("Missing header: " + name);
        return value;
    }

    static int intHeader(ConsumerRecord<byte[], byte[]> record, String name) {
        byte[] value = header(record, name);
        if (value.length != 4) throw new IllegalArgumentException("Invalid integer header: " + name);
        return ByteBuffer.wrap(value).getInt();
    }

    static long longHeader(ConsumerRecord<byte[], byte[]> record, String name) {
        byte[] value = header(record, name);
        if (value.length != 8) throw new IllegalArgumentException("Invalid long header: " + name);
        return ByteBuffer.wrap(value).getLong();
    }

    static String b64(byte[] value) { return value == null ? null : Base64.getEncoder().encodeToString(value); }
    static String sha256(byte[] value) throws Exception {
        if (value == null) return null;
        StringBuilder out = new StringBuilder();
        for (byte b : MessageDigest.getInstance("SHA-256").digest(value)) out.append(String.format("%02x", b & 255));
        return out.toString();
    }

    static String expectedPayloadHash(Map<String, String> options, boolean execute) {
        String expected = execute ? required(options, "payload-sha256") : options.get("payload-sha256");
        if (expected != null && !expected.matches("[0-9a-fA-F]{64}"))
            throw new IllegalArgumentException("--payload-sha256 must contain exactly 64 hexadecimal characters");
        return expected == null ? null : expected.toLowerCase(Locale.ROOT);
    }

    static void verifyPayloadHash(String actual, String expected) {
        if (expected != null && !MessageDigest.isEqual(actual.getBytes(StandardCharsets.US_ASCII),
                expected.getBytes(StandardCharsets.US_ASCII)))
            throw new IllegalArgumentException("Selected payload SHA256 does not match the confirmed preview");
    }

    static ConsumerRecord<byte[], byte[]> fetch(String bootstrap, String topic, int partition, long offset) {
        Properties p = base(bootstrap);
        p.put("key.deserializer", "org.apache.kafka.common.serialization.ByteArrayDeserializer");
        p.put("value.deserializer", "org.apache.kafka.common.serialization.ByteArrayDeserializer");
        p.put("enable.auto.commit", "false");
        p.put("allow.auto.create.topics", "false");
        p.put("max.poll.records", "1");
        TopicPartition tp = new TopicPartition(topic, partition);
        try (KafkaConsumer<byte[], byte[]> consumer = new KafkaConsumer<>(p)) {
            consumer.assign(Collections.singleton(tp));
            long beginning = consumer.beginningOffsets(Collections.singleton(tp)).get(tp);
            long end = consumer.endOffsets(Collections.singleton(tp)).get(tp);
            if (offset < beginning || offset >= end) throw new IllegalArgumentException("Selected offset does not exist");
            consumer.seek(tp, offset);
            long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(10);
            while (System.nanoTime() < deadline) {
                for (ConsumerRecord<byte[], byte[]> record : consumer.poll(Duration.ofMillis(250))) {
                    if (record.offset() != offset) throw new IllegalArgumentException("Exact selected offset is unavailable");
                    return record;
                }
            }
            throw new IllegalStateException("Timed out reading the exact selected DLT record");
        }
    }

    static void validate(ConsumerRecord<byte[], byte[]> record, String event, String target) {
        if (!record.topic().startsWith(PREFIX) || !record.topic().endsWith(".DLT") || !target.startsWith(PREFIX))
            throw new IllegalArgumentException("Only this card's p21-20261108-* topics are allowed");
        if (target.equals(record.topic()) || target.endsWith(".DLT"))
            throw new IllegalArgumentException("Replay target must be a source topic");
        if (!Arrays.equals(event.getBytes(StandardCharsets.UTF_8), header(record, "eventId")))
            throw new IllegalArgumentException("Selected event ID does not match the DLT record");
        if (!Arrays.equals(target.getBytes(StandardCharsets.UTF_8), header(record, ORIGINAL_TOPIC)))
            throw new IllegalArgumentException("Target does not match the preserved source topic");
        if (intHeader(record, ORIGINAL_PARTITION) < 0 || longHeader(record, ORIGINAL_OFFSET) < 0)
            throw new IllegalArgumentException("Invalid preserved source coordinates");
        if (record.value() == null) throw new IllegalArgumentException("Tombstone replay is not supported by this card");
    }

    static void append(FileChannel channel, Map<String, Object> entry) throws Exception {
        ByteBuffer bytes = ByteBuffer.wrap((JSON.toJSONString(entry) + "\n").getBytes(StandardCharsets.UTF_8));
        channel.position(channel.size());
        while (bytes.hasRemaining()) channel.write(bytes);
        channel.force(true);
    }

    static List<JSONObject> history(Path journal) throws Exception {
        List<JSONObject> result = new ArrayList<>();
        byte[] bytes = Files.readAllBytes(journal);
        if (bytes.length > 0 && bytes[bytes.length - 1] != '\n')
            throw new IllegalStateException("Incomplete journal tail; inspect it before further replay");
        for (String line : new String(bytes, StandardCharsets.UTF_8).split("\n"))
            if (!line.isEmpty()) result.add(JSON.parseObject(line));
        return result;
    }

    static List<JSONObject> lockedHistory(FileChannel channel) throws Exception {
        if (channel.size() > 10 * 1024 * 1024) throw new IllegalStateException("Journal exceeds this finite replay scope");
        ByteBuffer buffer = ByteBuffer.allocate((int) channel.size());
        channel.position(0);
        while (buffer.hasRemaining() && channel.read(buffer) >= 0) { }
        byte[] bytes = buffer.array();
        if (bytes.length > 0 && bytes[bytes.length - 1] != '\n')
            throw new IllegalStateException("Incomplete journal tail; inspect it before further replay");
        List<JSONObject> entries = new ArrayList<>();
        for (String line : new String(bytes, StandardCharsets.UTF_8).split("\\n"))
            if (!line.trim().isEmpty()) entries.add(JSON.parseObject(line));
        return entries;
    }

    public static void main(String[] args) throws Exception {
        Map<String, String> o = options(args);
        String bootstrap = required(o, "bootstrap");
        String dlt = required(o, "dlt-topic");
        int partition = Integer.parseInt(required(o, "partition"));
        long offset = Long.parseLong(required(o, "offset"));
        String event = required(o, "event-id");
        String target = required(o, "target-topic");
        String executeValue = o.getOrDefault("execute", "false");
        if (!executeValue.equals("true") && !executeValue.equals("false"))
            throw new IllegalArgumentException("--execute must be true or false");
        boolean execute = Boolean.parseBoolean(executeValue);
        String expectedHash = expectedPayloadHash(o, execute);
        double rate = Double.parseDouble(o.getOrDefault("rate", "1"));
        if (!Double.isFinite(rate) || rate < 0.1 || rate > 1 || partition < 0 || offset < 0)
            throw new IllegalArgumentException("Rate must be 0.1..1 record/s and coordinates nonnegative");
        if (!dlt.startsWith(PREFIX) || !dlt.endsWith(".DLT") || !target.startsWith(PREFIX))
            throw new IllegalArgumentException("Only this card's test topics are allowed");
        String replayId = execute ? required(o, "replay-id") : o.getOrDefault("replay-id", "preview");
        if (execute && !target.equals(required(o, "confirm-target")))
            throw new IllegalArgumentException("--confirm-target must equal --target-topic");
        Path journal = execute ? Paths.get(required(o, "journal")).toAbsolutePath() : null;

        ConsumerRecord<byte[], byte[]> record = fetch(bootstrap, dlt, partition, offset);
        validate(record, event, target);
        String payloadHash = sha256(record.value());
        verifyPayloadHash(payloadHash, expectedHash);
        int targetPartition = intHeader(record, ORIGINAL_PARTITION);
        try (AdminClient admin = AdminClient.create(base(bootstrap))) {
            TopicDescription desc = admin.describeTopics(Collections.singleton(target)).all()
                    .get(10, TimeUnit.SECONDS).get(target);
            if (targetPartition >= desc.partitions().size()) throw new IllegalArgumentException("Source partition does not exist");
        }
        List<Object> originalHeaders = new ArrayList<>();
        for (Header h : record.headers()) originalHeaders.add(row("name", h.key(), "value_base64", b64(h.value())));
        Map<String, Object> selected = row("dlt_topic", dlt, "dlt_partition", partition, "dlt_offset", offset,
                "event_id", event, "target_topic", target, "target_partition", targetPartition,
                "source_offset", longHeader(record, ORIGINAL_OFFSET), "key_base64", b64(record.key()),
                "payload_base64", b64(record.value()), "payload_sha256", payloadHash,
                "original_headers", originalHeaders);
        if (!execute) {
            System.out.println("RESULT " + JSON.toJSONString(row("status", "PREVIEW_ONLY", "selected", selected)));
            return;
        }
        if (!Files.isDirectory(journal.getParent())) throw new IllegalArgumentException("Journal parent directory must exist");
        try (FileChannel channel = FileChannel.open(journal, StandardOpenOption.CREATE, StandardOpenOption.READ, StandardOpenOption.WRITE);
             FileLock lock = channel.tryLock()) {
            if (lock == null) throw new IllegalStateException("Another replay owns this journal");
            int ordinal = 1;
            long latestIntent = 0;
            for (JSONObject item : lockedHistory(channel)) {
                if (replayId.equals(item.getString("replay_id"))) throw new IllegalArgumentException("Replay ID already used; inspect its recorded outcome");
                if ("SEND_INTENT".equals(item.getString("status"))) {
                    latestIntent = Math.max(latestIntent, item.getLongValue("epoch_ms"));
                    JSONObject prior = item.getJSONObject("selected");
                    if (dlt.equals(prior.getString("dlt_topic")) && partition == prior.getIntValue("dlt_partition")
                            && offset == prior.getLongValue("dlt_offset")) ordinal++;
                }
            }
            Properties p = base(bootstrap);
            p.put("key.serializer", "org.apache.kafka.common.serialization.ByteArraySerializer");
            p.put("value.serializer", "org.apache.kafka.common.serialization.ByteArraySerializer");
            p.put("acks", "all"); p.put("enable.idempotence", "true"); p.put("retries", "10");
            p.put("max.in.flight.requests.per.connection", "5"); p.put("delivery.timeout.ms", "12000");
            p.put("max.block.ms", "10000");
            try (KafkaProducer<byte[], byte[]> producer = new KafkaProducer<>(p)) {
                ProducerRecord<byte[], byte[]> outbound = new ProducerRecord<>(target, targetPartition, record.key(), record.value());
                for (Header h : record.headers()) outbound.headers().add(new RecordHeader(h.key(), h.value()));
                outbound.headers().add(new RecordHeader("p21_replay_id", replayId.getBytes(StandardCharsets.UTF_8)));
                outbound.headers().add(new RecordHeader("p21_replay_count", Integer.toString(ordinal).getBytes(StandardCharsets.UTF_8)));
                outbound.headers().add(new RecordHeader("p21_replay_dlt", (dlt + ":" + partition + ":" + offset).getBytes(StandardCharsets.UTF_8)));
                long wait = latestIntent + (long) Math.ceil(1000 / rate) - System.currentTimeMillis();
                if (wait > 10000) throw new IllegalStateException("Journal time is ahead of this clock; inspect before replay");
                if (wait > 0) Thread.sleep(wait);
                long started = System.currentTimeMillis();
                append(channel, row("status", "SEND_INTENT", "replay_id", replayId, "replay_ordinal", ordinal,
                        "epoch_ms", started, "utc", Instant.ofEpochMilli(started).toString(), "rate_per_second", rate,
                        "expected_payload_sha256", expectedHash, "selected", selected));
                RecordMetadata md;
                try {
                    md = producer.send(outbound).get(15, TimeUnit.SECONDS);
                } catch (Exception failure) {
                    append(channel, row("status", "SEND_NOT_CONFIRMED", "replay_id", replayId,
                            "epoch_ms", System.currentTimeMillis(), "exception", failure.getClass().getName(),
                            "message", failure.getMessage(), "note", "Delivery may have occurred; reconcile broker records before retry"));
                    throw failure;
                }
                Map<String, Object> receipt = row("status", "BROKER_ACKNOWLEDGED", "replay_id", replayId,
                        "event_id", event, "replay_ordinal", ordinal, "topic", md.topic(), "partition", md.partition(),
                        "offset", md.offset(), "epoch_ms", System.currentTimeMillis(), "payload_sha256", payloadHash);
                append(channel, receipt);
                System.out.println("RESULT " + JSON.toJSONString(receipt));
            }
        }
    }
}
