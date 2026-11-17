import com.heima.article.service.ApArticleService;
import com.heima.article.service.impl.ArticleFreemarkerServiceImpl;
import com.heima.article.support.DetailCacheInvalidator;
import com.heima.article.support.DetailProbe;
import com.heima.file.service.FileStorageService;
import com.heima.model.article.pojos.ApArticle;
import freemarker.template.Configuration;
import org.apache.kafka.clients.producer.ProducerConfig;
import org.springframework.kafka.core.DefaultKafkaProducerFactory;
import org.springframework.kafka.core.KafkaTemplate;
import org.springframework.kafka.support.SendResult;
import org.springframework.util.concurrent.ListenableFuture;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.InputStream;
import java.io.PrintWriter;
import java.lang.reflect.Field;
import java.lang.reflect.Proxy;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/**
 * B (rework): offline contract control on the DELIVERED POST class.
 *
 * <p>The defect the reviewer reproduced: {@code apArticleService.update(...)} was called without using
 * its boolean result, so a 0-row update (target article does not exist) still emitted
 * {@code static_url.updated} and still registered the invalidation. This program loads the real
 * compiled {@link ArticleFreemarkerServiceImpl} from the POST variant directory and drives it twice:</p>
 *
 * <ol>
 *   <li>DAO returns false  -> the skipped branch must run: no updated event, no invalidation, and the
 *       residual message call is counted so the kept trade-off is visible;</li>
 *   <li>DAO returns true   -> the success branch must run: updated event + exactly one invalidation.</li>
 * </ol>
 *
 * <p>Collaborators are recorded doubles; the Freemarker template is the real one from the repository.
 * This is a contract test only, not a substitute for the real async/MySQL run.</p>
 *
 * <p>Usage: java P13bZeroRowContract &lt;templateDir&gt; &lt;outFile&gt;</p>
 */
public class P13bZeroRowContract {

    /** records probe events instead of writing an event file */
    static class RecordingProbe extends DetailProbe {
        final List<String> events = new ArrayList<String>();

        @Override
        public void event(String name, long reqId, long articleId, String extra) {
            events.add(name + "|articleId=" + articleId + "|" + extra);
        }
    }

    /** records invalidator calls; never touches Redis (uses the real constructor) */
    static class RecordingInvalidator extends DetailCacheInvalidator {
        int calls = 0;
        String lastReason = "";

        RecordingInvalidator() {
            super(null, null);
        }

        @Override
        public void invalidateAfterWrite(Long articleId, String reason) {
            calls++;
            lastReason = reason;
        }
    }

    /** records the upload and returns a clearly marked experiment URL */
    static class RecordingStorage implements FileStorageService {
        int uploads = 0;
        String html = "";

        @Override
        public String uploadImgFile(String prefix, String filename, InputStream inputStream) {
            return "p13b-offline://img/" + prefix + filename;
        }

        @Override
        public String uploadHtmlFile(String prefix, String filename, InputStream inputStream) {
            uploads++;
            html = read(inputStream);
            return "p13b-offline://html/" + prefix + filename;
        }

        @Override
        public void delete(String pathUrl) {
        }

        @Override
        public byte[] downLoadFile(String pathUrl) {
            return new byte[0];
        }

        private String read(InputStream in) {
            try {
                ByteArrayOutputStream out = new ByteArrayOutputStream();
                byte[] buf = new byte[4096];
                int n;
                while ((n = in.read(buf)) > 0) {
                    out.write(buf, 0, n);
                }
                return new String(out.toByteArray(), StandardCharsets.UTF_8);
            } catch (Exception e) {
                return "read_error";
            }
        }
    }

    /** records kafka calls and never connects */
    static class RecordingKafka extends KafkaTemplate<String, String> {
        int sends = 0;
        String lastPayload = "";

        RecordingKafka() {
            super(factory());
        }

        private static DefaultKafkaProducerFactory<String, String> factory() {
            Map<String, Object> cfg = new HashMap<String, Object>();
            cfg.put(ProducerConfig.BOOTSTRAP_SERVERS_CONFIG, "p13b-offline-never-used:9092");
            return new DefaultKafkaProducerFactory<String, String>(cfg);
        }

        @Override
        public ListenableFuture<SendResult<String, String>> send(String topic, String data) {
            sends++;
            lastPayload = data;
            return null;
        }

        @Override
        public ListenableFuture<SendResult<String, String>> send(String topic, String key, String data) {
            sends++;
            lastPayload = data;
            return null;
        }
    }

    static void setField(Object target, String name, Object value) throws Exception {
        Field f = target.getClass().getDeclaredField(name);
        f.setAccessible(true);
        f.set(target, value);
    }

    /** returns the configured update(Wrapper) result and counts the call */
    static ApArticleService dao(final boolean updateResult, final int[] updateCalls) {
        return (ApArticleService) Proxy.newProxyInstance(
                P13bZeroRowContract.class.getClassLoader(),
                new Class<?>[]{ApArticleService.class},
                (p, m, a) -> {
                    if ("update".equals(m.getName())) {
                        updateCalls[0]++;
                        return updateResult;
                    }
                    Class<?> rt = m.getReturnType();
                    if (rt == boolean.class) { return Boolean.FALSE; }
                    if (rt == int.class) { return Integer.valueOf(0); }
                    if (rt == long.class) { return Long.valueOf(0L); }
                    if (rt == short.class) { return Short.valueOf((short) 0); }
                    if (rt == byte.class) { return Byte.valueOf((byte) 0); }
                    if (rt == double.class) { return Double.valueOf(0d); }
                    if (rt == float.class) { return Float.valueOf(0f); }
                    return null;
                });
    }

    /** MyBatis-Plus resolves lambda columns from a TableInfo cache; the framework normally fills it. */
    static void initTableInfo() {
        try {
            com.baomidou.mybatisplus.core.MybatisConfiguration mpConfiguration =
                    new com.baomidou.mybatisplus.core.MybatisConfiguration();
            org.apache.ibatis.builder.MapperBuilderAssistant assistant =
                    new org.apache.ibatis.builder.MapperBuilderAssistant(mpConfiguration, "");
            com.baomidou.mybatisplus.core.metadata.TableInfoHelper.initTableInfo(assistant, ApArticle.class);
        } catch (Throwable t) {
            System.out.println("table_info_init_warning=" + t.getClass().getSimpleName() + ":" + t.getMessage());
        }
    }

    static String run(boolean updateResult, String templateDir) throws Exception {
        int[] updateCalls = new int[1];
        RecordingProbe probe = new RecordingProbe();
        RecordingInvalidator invalidator = new RecordingInvalidator();
        RecordingStorage storage = new RecordingStorage();
        RecordingKafka kafka = new RecordingKafka();

        Configuration cfg = new Configuration(Configuration.VERSION_2_3_31);
        cfg.setDirectoryForTemplateLoading(new File(templateDir));
        cfg.setDefaultEncoding("UTF-8");

        ArticleFreemarkerServiceImpl svc = new ArticleFreemarkerServiceImpl();
        setField(svc, "apArticleContentMapper", null);
        setField(svc, "configuration", cfg);
        setField(svc, "fileStorageService", storage);
        setField(svc, "apArticleService", dao(updateResult, updateCalls));
        setField(svc, "detailCacheInvalidator", invalidator);
        setField(svc, "probe", probe);
        setField(svc, "kafkaTemplate", kafka);

        ApArticle article = new ApArticle();
        article.setId(9007199254741015L);
        svc.buildArticleToMinIO(article, "[{\"type\":\"text\",\"value\":\"P13b-marker\"}]");

        boolean hasUpdated = false;
        boolean hasSkipped = false;
        for (String e : probe.events) {
            if (e.startsWith("static_url.updated|")) { hasUpdated = true; }
            if (e.startsWith("static_url.update_skipped|")) { hasSkipped = true; }
        }
        StringBuilder detail = new StringBuilder();
        detail.append("dao=").append(updateResult)
                .append(" update_calls=").append(updateCalls[0])
                .append(" uploads=").append(storage.uploads)
                .append(" template_rendered=").append(storage.html.contains("P13b-marker"))
                .append(" html_bytes=").append(storage.html.length())
                .append(" events=").append(probe.events.size())
                .append(" event_updated=").append(hasUpdated)
                .append(" event_skipped=").append(hasSkipped)
                .append(" invalidation_calls=").append(invalidator.calls)
                .append(" invalidation_reason=").append(invalidator.lastReason.isEmpty() ? "-" : invalidator.lastReason)
                .append(" kafka_sends=").append(kafka.sends)
                .append(" kafka_has_marker=").append(kafka.lastPayload.contains("P13b-marker"));
        return detail.toString();
    }

    public static void main(String[] args) throws Exception {
        if (args.length < 2) {
            System.out.println("usage: P13bZeroRowContract <templateDir> <outFile>");
            System.exit(2);
        }
        String templateDir = args[0];
        String outFile = args[1];
        initTableInfo();

        List<String> report = new ArrayList<String>();

        String falseRun = run(false, templateDir);
        boolean falseOk = falseRun.contains("update_calls=1")
                && falseRun.contains("event_updated=false")
                && falseRun.contains("event_skipped=true")
                && falseRun.contains("invalidation_calls=0")
                && falseRun.contains("template_rendered=true")
                && falseRun.contains("kafka_sends=1");
        report.add("B.false_control|" + (falseOk ? "PASS" : "FAIL") + "|" + falseRun);

        String trueRun = run(true, templateDir);
        boolean trueOk = trueRun.contains("update_calls=1")
                && trueRun.contains("event_updated=true")
                && trueRun.contains("event_skipped=false")
                && trueRun.contains("invalidation_calls=1")
                && trueRun.contains("invalidation_reason=static_url:afterUpdate")
                && trueRun.contains("template_rendered=true")
                && trueRun.contains("kafka_sends=1");
        report.add("B.true_control|" + (trueOk ? "PASS" : "FAIL") + "|" + trueRun);

        PrintWriter w = new PrintWriter(outFile, "UTF-8");
        for (String line : report) {
            w.println(line);
        }
        w.close();
        for (String line : report) {
            System.out.println(line);
        }
        System.exit((falseOk && trueOk) ? 0 : 1);
    }
}
