package binge.gates

import org.gradle.api.GradleException
import org.gradle.api.Project
import org.gradle.testfixtures.ProjectBuilder
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.io.TempDir
import java.io.File

/** Stamps a small module's strings with the update task, then runs the check against them. */
class CheckTranslationStalenessTaskTest {
    @TempDir
    lateinit var root: File

    private lateinit var project: Project

    @BeforeEach
    fun stampHashes() {
        project = ProjectBuilder.builder().withProjectDir(root).build()
        strings("values", "greeting" to "Hello", "farewell" to "Goodbye")
        strings("values-es", "greeting" to "Hola", "farewell" to "Adiós")
        task("updateTranslationHashes", rewrite = true).check()
    }

    @Test
    fun `passes when every translated source string matches its hash`() {
        task("checkTranslationStaleness", rewrite = false).check()
    }

    @Test
    fun `fails and names a source string reworded since it was stamped`() {
        strings("values", "greeting" to "Hi there", "farewell" to "Goodbye")

        val failure =
            assertThrows(GradleException::class.java) {
                task("checkTranslationStaleness", rewrite = false).check()
            }

        val message = failure.message.orEmpty()
        assertTrue(message.contains("app:greeting"), message)
        assertFalse(message.contains("app:farewell"), message)
    }

    @Test
    fun `hashes only strings some locale translates, and skips untranslatable ones`() {
        File(root, "app/src/main/res/values/strings.xml").writeText(
            """
            <resources>
                <string name="greeting">Hello</string>
                <string name="english_only">Only here</string>
                <string name="brand" translatable="false">Brand</string>
            </resources>
            """.trimIndent(),
        )
        File(root, "app/src/main/res/values-es/strings.xml").writeText(
            """<resources><string name="greeting">Hola</string><string name="brand">Marca</string></resources>""",
        )

        val hashes = computeHashes(root, project.fileTree(root) { include("**/strings.xml") }.files)

        assertEquals(setOf("app:greeting"), hashes.keys)
    }

    @Test
    fun `hashes strings in a project at the root directory itself`() {
        File(root, "src/main/res/values").mkdirs()
        File(root, "src/main/res/values-es").mkdirs()
        File(root, "src/main/res/values/strings.xml")
            .writeText("""<resources><string name="greeting">Hello</string></resources>""")
        File(root, "src/main/res/values-es/strings.xml")
            .writeText("""<resources><string name="greeting">Hola</string></resources>""")

        val hashes = computeHashes(root, project.fileTree(root) { include("src/**/strings.xml") }.files)

        assertEquals(setOf(".:greeting"), hashes.keys)
    }

    @Test
    fun `refuses when the globs find no strings file`() {
        val failure =
            assertThrows(GradleException::class.java) {
                task("updateWithNoFiles", rewrite = true, include = "nowhere/**/strings.xml").check()
            }

        assertTrue(failure.message.orEmpty().contains("found no strings file"), failure.message)
    }

    @Test
    fun `refuses when translations have no source file under the same module key`() {
        val failure =
            assertThrows(GradleException::class.java) {
                task("checkWithNoSource", rewrite = false, include = "app/src/*/res/values-*/strings.xml").check()
            }

        val message = failure.message.orEmpty()
        assertTrue(message.contains("no source strings file"), message)
        assertTrue(message.contains("app"), message)
    }

    @Test
    fun `passes when no locale translates any source string yet`() {
        File(root, "app/src/main/res/values-es/strings.xml").delete()
        task("restamp", rewrite = true).check()

        task("checkTranslationStaleness", rewrite = false).check()
    }

    @Test
    fun `reads only locale-qualified directories as translations`() {
        val kinds =
            listOf(
                "values", "values-es", "values-es-rUS", "values-b+sr+Latn", "values-mcc310-es", "values-es-night",
                "values-night", "values-sw600dp", "values-v21", "values-land", "values-car", "values-mcc310",
            ).associateWith { resourceKindOf("app/src/main/res/$it/strings.xml") }

        assertEquals(StringsKind.SOURCE, kinds["values"])
        listOf("values-es", "values-es-rUS", "values-b+sr+Latn", "values-mcc310-es", "values-es-night")
            .forEach { assertEquals(StringsKind.TRANSLATION, kinds[it], it) }
        listOf("values-night", "values-sw600dp", "values-v21", "values-land", "values-car", "values-mcc310")
            .forEach { assertEquals(null, kinds[it], it) }
    }

    @Test
    fun `a configuration override is neither hashed nor read as an orphaned translation`() {
        strings("values-night", "greeting" to "Hello, night owl")
        task("restampWithNight", rewrite = true).check()

        val hashes = computeHashes(root, project.fileTree(root) { include("app/src/*/res/values*/strings.xml") }.files)
        assertEquals(setOf("app:greeting", "app:farewell"), hashes.keys)

        File(root, "app/src/main/res/values-es/strings.xml").delete()
        assertEquals(
            null,
            misconfiguration(root, project.fileTree(root) { include("app/src/*/res/values*/strings.xml") }.files),
        )
    }

    @Test
    fun `a translated string array is hashed, and rewording one item fails the check`() {
        withArray("values", "Rating 0 to 2", "Rating 3 to 4")
        withArray("values-es", "Valoración de 0 a 2", "Valoración de 3 a 4")
        task("stampArrays", rewrite = true).check()
        task("checkArrays", rewrite = false).check()

        withArray("values", "0 to 2 stars", "Rating 3 to 4")

        val failure =
            assertThrows(GradleException::class.java) {
                task("checkReworded", rewrite = false).check()
            }
        val message = failure.message.orEmpty()
        assertTrue(message.contains("app:ratings"), message)
        assertFalse(message.contains("app:greeting"), message)
    }

    @Test
    fun `an unstamped translated string array is reported as newly translated`() {
        withArray("values", "Rating 0 to 2")
        withArray("values-es", "Valoración de 0 a 2")

        val failure =
            assertThrows(GradleException::class.java) {
                task("checkUnstamped", rewrite = false).check()
            }

        val message = failure.message.orEmpty()
        assertTrue(message.contains("Newly translated, not yet stamped"), message)
        assertTrue(message.contains("app:ratings"), message)
    }

    @Test
    fun `item boundaries are part of the hash, so splitting an item changes it`() {
        val joined = hashesWithArray("a b")
        val split = hashesWithArray("a", "b")

        assertTrue(joined.getValue("app:ratings") != split.getValue("app:ratings"))
    }

    @Test
    fun `an untranslated or untranslatable string array is not hashed`() {
        File(root, "app/src/main/res/values/strings.xml").writeText(
            """
            <resources>
                <string name="greeting">Hello</string>
                <string-array name="english_only"><item>One</item></string-array>
                <string-array name="brands" translatable="false"><item>Brand</item></string-array>
            </resources>
            """.trimIndent(),
        )
        File(root, "app/src/main/res/values-es/strings.xml").writeText(
            """<resources><string name="greeting">Hola</string><string-array name="brands"><item>Marca</item></string-array></resources>""",
        )

        val hashes = computeHashes(root, project.fileTree(root) { include("**/strings.xml") }.files)

        assertEquals(setOf("app:greeting"), hashes.keys)
    }

    private fun hashesWithArray(vararg items: String): Map<String, String> {
        withArray("values", *items)
        withArray("values-es", *items.map { "es $it" }.toTypedArray())
        return computeHashes(root, project.fileTree(root) { include("**/strings.xml") }.files)
    }

    private fun withArray(
        directory: String,
        vararg items: String,
    ): File {
        val file = File(root, "app/src/main/res/$directory/strings.xml")
        val array = items.joinToString("\n", "    <string-array name=\"ratings\">\n", "\n    </string-array>") { """        <item>$it</item>""" }
        val strings = file.readText().substringBefore("</resources>")
        return file.apply { writeText("$strings$array\n</resources>\n") }
    }

    private fun task(
        name: String,
        rewrite: Boolean,
        include: String = "app/src/*/res/values*/strings.xml",
    ) = project.tasks
        .register(name, CheckTranslationStalenessTask::class.java) {
            stringFiles.from(project.fileTree(root) { include(include) })
            hashFile.set(File(root, "translation-hashes.txt"))
            repoRoot.set(root)
            this.rewrite.set(rewrite)
        }.get()

    private fun strings(
        directory: String,
        vararg entries: Pair<String, String>,
    ): File =
        File(root, "app/src/main/res/$directory/strings.xml").apply {
            parentFile.mkdirs()
            writeText(
                entries.joinToString("\n", "<resources>\n", "\n</resources>\n") { (name, value) ->
                    """    <string name="$name">$value</string>"""
                },
            )
        }
}
