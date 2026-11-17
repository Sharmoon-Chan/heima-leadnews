import com.baomidou.mybatisplus.autoconfigure.MybatisPlusProperties;
import com.baomidou.mybatisplus.autoconfigure.MybatisPlusPropertiesCustomizer;
import com.baomidou.mybatisplus.core.incrementer.IdentifierGenerator;
import com.heima.article.p13b.P13bHarnessConfig;
import com.heima.model.article.pojos.ApArticle;
import com.heima.model.article.pojos.ApArticleConfig;
import com.heima.model.article.pojos.ApArticleContent;

import java.io.PrintWriter;
import java.lang.reflect.Method;
import java.util.ArrayList;
import java.util.List;

/**
 * D (rework): offline scope check of the DELIVERED ID fixture class.
 *
 * <p>The reviewer's finding: the fixture only tested {@code entity instanceof ApArticle}, so ANY new
 * article - marked or not - received the same fixed id. The requirement is: the fixed id goes only to
 * the article that carries the exact test marker (title), every other article and every other entity
 * delegates to the real MyBatis-Plus generator.</p>
 *
 * <p>Three states checked on the real harness class:</p>
 * <ol>
 *   <li>marked ApArticle (title == marker)  -> fixed id;</li>
 *   <li>plain ApArticle (any other title)   -> NOT the fixed id;</li>
 *   <li>ApArticleConfig / ApArticleContent  -> independent keys, never the fixed id.</li>
 * </ol>
 *
 * <p>Also reads the bean method annotations to confirm the fixture is still off by default.</p>
 *
 * <p>Usage: java P13bIdFixtureOffline &lt;fixedId&gt; &lt;markerTitle&gt; &lt;outFile&gt;</p>
 */
public class P13bIdFixtureOffline {

    private static IdentifierGenerator install(long fixedId, String marker) {
        P13bHarnessConfig cfg = new P13bHarnessConfig();
        MybatisPlusPropertiesCustomizer customizer = cfg.p13bArticleIdFixture(fixedId, marker);
        MybatisPlusProperties props = new MybatisPlusProperties();
        customizer.customize(props);
        return props.getGlobalConfig().getIdentifierGenerator();
    }

    private static ApArticle article(String title) {
        ApArticle a = new ApArticle();
        a.setTitle(title);
        return a;
    }

    public static void main(String[] args) throws Exception {
        if (args.length < 3) {
            System.out.println("usage: P13bIdFixtureOffline <fixedId> <markerTitle> <outFile>");
            System.exit(2);
        }
        long fixedId = Long.parseLong(args[0]);
        String marker = args[1];
        String outFile = args[2];

        List<String> report = new ArrayList<String>();

        IdentifierGenerator gen = install(fixedId, marker);
        long markedId = gen.nextId(article(marker)).longValue();
        long plainId1 = gen.nextId(article("P13b-plain-a")).longValue();
        long plainId2 = gen.nextId(article("P13b-plain-b")).longValue();
        long configId = gen.nextId(new ApArticleConfig()).longValue();
        long contentId = gen.nextId(new ApArticleContent()).longValue();

        boolean markedOk = (markedId == fixedId);
        report.add("D.marked_article_fixed_id|" + (markedOk ? "PASS" : "FAIL")
                + "|title='" + marker + "' id=" + markedId + " expected=" + fixedId);

        boolean plainOk = (plainId1 != fixedId) && (plainId2 != fixedId) && (plainId1 != plainId2);
        report.add("D.plain_article_delegates|" + (plainOk ? "PASS" : "FAIL")
                + "|plain ids=" + plainId1 + "," + plainId2 + " fixed=" + fixedId
                + " neither_equals_fixed=" + ((plainId1 != fixedId) && (plainId2 != fixedId))
                + " distinct=" + (plainId1 != plainId2));

        boolean otherOk = (configId != fixedId) && (contentId != fixedId) && (configId != contentId)
                && (configId != markedId) && (contentId != markedId);
        report.add("D.other_entities_own_keys|" + (otherOk ? "PASS" : "FAIL")
                + "|config=" + configId + " content=" + contentId + " fixed=" + fixedId
                + " distinct_from_each_other=" + (configId != contentId));

        // the fixture must still be conditional: gating annotation present on the bean method
        Method m = P13bHarnessConfig.class.getMethod("p13bArticleIdFixture", long.class, String.class);
        boolean gated = false;
        StringBuilder ann = new StringBuilder();
        for (java.lang.annotation.Annotation a : m.getAnnotations()) {
            ann.append(a.annotationType().getSimpleName()).append(",");
            if (a.annotationType().getSimpleName().equals("ConditionalOnProperty")) {
                gated = String.valueOf(a).contains("article.p13b.id-fixture.article-id");
            }
        }
        report.add("D.fixture_still_conditional|" + (gated ? "PASS" : "FAIL")
                + "|method_annotations=" + ann + " names_the_fixture_property=" + gated);

        PrintWriter w = new PrintWriter(outFile, "UTF-8");
        for (String line : report) {
            w.println(line);
        }
        w.close();

        boolean allOk = markedOk && plainOk && otherOk && gated;
        for (String line : report) {
            System.out.println(line);
        }
        System.exit(allOk ? 0 : 1);
    }
}
