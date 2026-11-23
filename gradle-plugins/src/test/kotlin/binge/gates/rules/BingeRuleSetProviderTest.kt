package binge.gates.rules

import dev.detekt.api.RuleSetProvider
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import java.util.ServiceLoader

private val RULE_IDS = setOf("BannerComment", "ConsecutiveInlineComments", "DeclarationCommentShouldBeKDoc", "KDocLength")

class BingeRuleSetProviderTest {
    @Test
    fun `the provider registers every comment rule under the binge id`() {
        val provider = BingeRuleSetProvider()

        assertEquals("binge", provider.ruleSetId.value)
        assertEquals(
            RULE_IDS,
            provider
                .instance()
                .rules
                .keys
                .map { it.value }
                .toSet(),
        )
    }

    @Test
    fun `detekt can discover the provider through its service file`() {
        val providers = ServiceLoader.load(RuleSetProvider::class.java).map { it::class }

        assertTrue(BingeRuleSetProvider::class in providers, "META-INF/services is missing or names another class: $providers")
    }
}
