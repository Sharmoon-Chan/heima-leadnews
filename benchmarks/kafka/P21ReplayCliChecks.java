import org.apache.kafka.clients.consumer.ConsumerRecord;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.nio.channels.FileChannel;
import java.nio.channels.FileLock;
import java.nio.file.*;
import java.util.Arrays;
import java.util.Collections;

/** Offline guard checks only; broker delivery is verified separately by P2.1 scenarios. */
public final class P21ReplayCliChecks {
    static int passed;
    interface Checked { void run() throws Exception; }
    static void rejects(Checked action) throws Exception {
        try { action.run(); } catch (IllegalArgumentException | IllegalStateException expected) { passed++; return; }
        throw new AssertionError("Expected rejection");
    }
    static ConsumerRecord<byte[], byte[]> fixture() {
        ConsumerRecord<byte[], byte[]> record = new ConsumerRecord<>("p21-20261108-offline.DLT", 0, 5,
                new byte[]{0, (byte) 255}, new byte[]{0, 1, (byte) 255});
        record.headers().add("eventId", "event-1".getBytes(StandardCharsets.UTF_8));
        record.headers().add(P21ReplayCli.ORIGINAL_TOPIC, "p21-20261108-offline".getBytes(StandardCharsets.UTF_8));
        record.headers().add(P21ReplayCli.ORIGINAL_PARTITION, ByteBuffer.allocate(4).putInt(0).array());
        record.headers().add(P21ReplayCli.ORIGINAL_OFFSET, ByteBuffer.allocate(8).putLong(9).array());
        return record;
    }
    public static void main(String[] args) throws Exception {
        ConsumerRecord<byte[], byte[]> valid = fixture();
        P21ReplayCli.validate(valid, "event-1", "p21-20261108-offline"); passed++;
        rejects(() -> P21ReplayCli.validate(fixture(), "different-event", "p21-20261108-offline"));
        rejects(() -> P21ReplayCli.validate(fixture(), "event-1", "p21-20261108-wrong"));
        rejects(() -> P21ReplayCli.validate(fixture(), "event-1", "article.es.sync.topic"));
        ConsumerRecord<byte[], byte[]> noEvent = fixture(); noEvent.headers().remove("eventId");
        rejects(() -> P21ReplayCli.validate(noEvent, "event-1", "p21-20261108-offline"));
        ConsumerRecord<byte[], byte[]> conflict = fixture(); conflict.headers().add("eventId", new byte[]{9});
        rejects(() -> P21ReplayCli.validate(conflict, "event-1", "p21-20261108-offline"));
        ConsumerRecord<byte[], byte[]> badCoordinate = fixture();
        badCoordinate.headers().remove(P21ReplayCli.ORIGINAL_OFFSET);
        badCoordinate.headers().add(P21ReplayCli.ORIGINAL_OFFSET, new byte[]{1});
        rejects(() -> P21ReplayCli.validate(badCoordinate, "event-1", "p21-20261108-offline"));
        rejects(() -> P21ReplayCli.options(new String[]{"--execute", "true", "--execute", "false"}));
        rejects(() -> P21ReplayCli.expectedPayloadHash(Collections.emptyMap(), true));
        rejects(() -> P21ReplayCli.expectedPayloadHash(Collections.singletonMap("payload-sha256", "invalid"), true));
        String actualHash = P21ReplayCli.sha256(valid.value());
        String expectedHash = P21ReplayCli.expectedPayloadHash(Collections.singletonMap("payload-sha256", actualHash.toUpperCase()), true);
        P21ReplayCli.verifyPayloadHash(actualHash, expectedHash); passed++;
        rejects(() -> P21ReplayCli.verifyPayloadHash(actualHash, String.join("", Collections.nCopies(64, "0"))));
        if (P21ReplayCli.expectedPayloadHash(Collections.emptyMap(), false) != null) throw new AssertionError("Preview requires a hash");
        passed++;
        Path journal = Paths.get(args[0]);
        try (FileChannel channel = FileChannel.open(journal, StandardOpenOption.CREATE_NEW, StandardOpenOption.READ, StandardOpenOption.WRITE);
             FileLock lock = channel.tryLock()) {
            if (lock == null || !lock.isValid()) throw new AssertionError("No exclusive journal lock");
            if (!P21ReplayCli.lockedHistory(channel).isEmpty()) throw new AssertionError("Fresh journal is not empty");
            passed++;
            P21ReplayCli.append(channel, P21ReplayCli.row("status", "SEND_INTENT", "replay_id", "offline-1",
                    "payload_base64", P21ReplayCli.b64(valid.value())));
            byte[] restored = java.util.Base64.getDecoder().decode(P21ReplayCli.lockedHistory(channel).get(0).getString("payload_base64"));
            if (!Arrays.equals(valid.value(), restored)) throw new AssertionError("Journal corrupted original bytes");
            passed++;
            P21ReplayCli.append(channel, P21ReplayCli.row("status", "BROKER_ACKNOWLEDGED", "replay_id", "offline-1"));
            if (P21ReplayCli.lockedHistory(channel).size() != 2) throw new AssertionError("Locked append/read lost an entry");
            passed++;
            channel.position(channel.size()); channel.write(ByteBuffer.wrap(new byte[]{'{'})); channel.force(true);
            rejects(() -> P21ReplayCli.lockedHistory(channel));
        }
        System.out.println("RESULT {\"checks\":" + passed + ",\"passed\":" + passed + ",\"kind\":\"offline_guards_only\"}");
    }
}
