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

    private fun task(
        name: String,
        rewrite: Boolean,
    ) = project.tasks
        .register(name, CheckTranslationStalenessTask::class.java) {
            stringFiles.from(project.fileTree(root) { include("app/src/*/res/values*/strings.xml") })
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
