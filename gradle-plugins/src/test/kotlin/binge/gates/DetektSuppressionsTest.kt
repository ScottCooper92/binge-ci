package binge.gates

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Test

class DetektSuppressionsTest {
    @Test
    fun `every named rule set gets the globs`() {
        assertEquals(
            "style:\n  excludes: ['**/*PreviewData.kt', '**/Fake.kt']\nbinge:\n  excludes: ['**/*PreviewData.kt', '**/Fake.kt']\n",
            suppressionsYaml(listOf("**/*PreviewData.kt", "**/Fake.kt"), listOf("style", "binge")),
        )
    }

    @Test
    fun `a rule set's own excludes is found, a rule's is not`() {
        val config =
            """
            # complexity has one on a rule
            complexity:
              LongMethod:
                excludes: ['**/Generated.kt']
            style:
              excludes: ['**/Other.kt']
              MagicNumber:
                active: true
            Compose:
              excludes: ['**/Previews.kt']
            """.trimIndent()

        assertEquals(listOf("style", "Compose"), ruleSetsWithOwnExcludes(config))
    }

    @Test
    fun `a comment line and a blank line do not move the rule set`() {
        val config = "potential-bugs:\n\n  # a note\n  excludes: ['**/A.kt']\n"

        assertEquals(listOf("potential-bugs"), ruleSetsWithOwnExcludes(config))
    }

    @Test
    fun `a config with no excludes finds none`() {
        assertEquals(emptyList<String>(), ruleSetsWithOwnExcludes("style:\n  MagicNumber:\n    active: true\n"))
    }

    @Test
    fun `a config indented with four spaces is read the same`() {
        val config = "style:\n    excludes: ['**/Other.kt']\n    MagicNumber:\n        excludes: ['**/Fake.kt']\n"

        assertEquals(listOf("style"), ruleSetsWithOwnExcludes(config))
    }
}
