package binge.gates

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Test

class StaleBaselineEntriesTest {
    private val baseline =
        """
        <?xml version="1.0" ?>
        <SmellBaseline>
          <ManuallySuppressedIssues/>
          <CurrentIssues>
            <ID>LongMethod:Screen.kt${'$'}fun Screen()</ID>
            <ID>MagicNumber:Mapper.kt${'$'}42</ID>
            <ID>MagicNumber:Mapper.kt${'$'}7</ID>
          </CurrentIssues>
        </SmellBaseline>
        """.trimIndent()

    @Test
    fun `passes when the report still produces every baselined finding`() {
        val report =
            report(
                "src/main/kotlin/ui/Screen.kt" to listOf("LongMethod"),
                "src/main/kotlin/data/Mapper.kt" to listOf("MagicNumber", "MagicNumber"),
            )

        assertEquals(emptyList<String>(), staleBaselineEntries(baseline, report))
    }

    @Test
    fun `names a rule and file the code no longer produces, counted`() {
        val report = report("src/main/kotlin/data/Mapper.kt" to listOf("MagicNumber"))

        assertEquals(
            listOf(
                "LongMethod in Screen.kt - baselined 1, reported 0",
                "MagicNumber in Mapper.kt - baselined 2, reported 1",
            ),
            staleBaselineEntries(baseline, report),
        )
    }

    private fun report(vararg files: Pair<String, List<String>>): String =
        buildString {
            append("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<checkstyle version=\"4.3\">\n")
            files.forEach { (path, rules) ->
                append("<file name=\"$path\">\n")
                rules.forEach { append("\t<error line=\"1\" column=\"1\" severity=\"error\" message=\"m\" source=\"detekt.$it\" />\n") }
                append("</file>\n")
            }
            append("</checkstyle>\n")
        }
}
