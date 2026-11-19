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

class DetektConfigClashesTest {
    @Test
    fun `a list written as items or inline is found at the third level, and the keys of an item are not`() {
        val config =
            """
            style:
              ForbiddenMethodCall:
                active: true
                excludes: ['**/build/**']
                methods:
                  - value: 'kotlin.runCatching'
                    reason: 'swallows cancellation'
              MagicNumber:
                active: true
            potential-bugs:
              UnsafeCallOnNullableType:
                active: true
            """.trimIndent()

        assertEquals(setOf("style>ForbiddenMethodCall>excludes", "style>ForbiddenMethodCall>methods"), listKeys(config))
    }

    @Test
    fun `a rule set's own list, a scalar and a comment are not a rule's list`() {
        val config = "# note\nstyle:\n  excludes: ['**/A.kt']\n  MagicNumber:\n    active: true\n    ignoreNumbers: '-1'\n"

        assertEquals(emptySet<String>(), listKeys(config))
    }

    @Test
    fun `a list under a key at the same indent as its items is found`() {
        assertEquals(setOf("style>Rule>methods"), listKeys("style:\n  Rule:\n    methods:\n    - value: 'a'\n"))
    }

    @Test
    fun `only a list that two files both set clashes, and the files are named in order`() {
        val own = "style:\n  ForbiddenMethodCall:\n    methods:\n      - value: 'kotlin.runCatching'\n"
        val fragment =
            "style:\n  ForbiddenImport:\n    forbiddenImports:\n      - value: 'a.B'\n  ForbiddenMethodCall:\n    methods:\n      - value: 'a.c'\n"

        assertEquals(
            mapOf("style>ForbiddenMethodCall>methods" to listOf("detekt.yml", "bans.yml")),
            clashingLists(listOf("detekt.yml" to own, "bans.yml" to fragment)),
        )
        assertEquals(emptyMap<String, List<String>>(), clashingLists(listOf("detekt.yml" to "style:\n  MagicNumber:\n    active: true\n", "bans.yml" to fragment)))
    }
}
