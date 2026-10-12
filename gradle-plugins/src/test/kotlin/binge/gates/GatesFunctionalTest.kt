package binge.gates

import org.gradle.testkit.runner.GradleRunner
import org.gradle.testkit.runner.TaskOutcome
import org.gradle.testkit.runner.internal.PluginUnderTestMetadataReading
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.io.TempDir
import java.io.File

/** Applies the plugins by id in a real build, so the wiring into `check` is what is tested. */
class GatesFunctionalTest {
    @TempDir
    lateinit var root: File

    @Test
    fun `translation staleness passes once stamped and fails check after a source edit`() {
        build("""plugins { id("binge.gates.translation-staleness") }""")
        write("app/src/main/res/values/strings.xml", """<resources><string name="greeting">Hello</string></resources>""")
        write("app/src/main/res/values-es/strings.xml", """<resources><string name="greeting">Hola</string></resources>""")

        runner("updateTranslationHashes").build()
        runner("check").build()

        write("app/src/main/res/values/strings.xml", """<resources><string name="greeting">Hi there</string></resources>""")
        val result = runner("check").buildAndFail()

        assertTrue(result.output.contains("app:greeting"), result.output)
    }

    @Test
    fun `tv-material separation fails check on a TV file importing Material 3`() {
        build(
            """
            plugins { id("binge.gates.tv-material-separation") }
            tvMaterialSeparation {
                sources.from(fileTree("src") { include("**/*.kt") })
                themeTypeNames.add("AppColors")
            }
            """.trimIndent(),
        )
        write("src/main/kotlin/app/tv/Home.kt", "package app.tv\n\nimport androidx.compose.material3.Text\n")

        val result = runner("check").buildAndFail()

        assertTrue(result.output.contains("src/main/kotlin/app/tv/Home.kt:3: TV source imports"), result.output)
        assertTrue(result.output.contains("AppColors"), result.output)
    }

    @Test
    fun `detekt gate adds the custom rules project, and baseline staleness skips with no baseline on disk`() {
        build(
            """
            plugins { id("binge.gates.baseline-staleness") }
            detektGate {
                customRulesProject.set(":rules")
                baselineFile.set(layout.projectDirectory.file("config/baseline.xml"))
            }
            tasks.register("printRules") {
                val rules = configurations.getByName("detektPlugins").dependencies
                doLast { println("rules=" + rules.joinToString { it.name }) }
            }
            """.trimIndent(),
            settings = "include(\":rules\")",
        )
        // A rules project is a JVM library, as a real one is: an empty project offers no variant to resolve.
        write("rules/build.gradle.kts", "plugins { `java-library` }")

        val rules = runner("printRules").build()
        val staleness = runner("checkBaselineStaleness").build()

        assertTrue(rules.output.contains("rules=rules"), rules.output)
        // No Kotlin plugin on this fixture's classpath is the non-Kotlin consumer, tested on purpose.
        assertTrue(rules.output.contains("no Kotlin Gradle plugin on the build classpath"), rules.output)
        assertEquals(TaskOutcome.SKIPPED, staleness.task(":detektWithoutBaseline")?.outcome, staleness.output)
        assertEquals(TaskOutcome.SKIPPED, staleness.task(":checkBaselineStaleness")?.outcome, staleness.output)
    }

    // UnsafeCallOnNullableType needs type resolution: with no classpath on the detekt task it loads
    // and never fires. So a `!!` failing `check` here, and passing once removed, is the proof that
    // the gate wired the compile classpath on.
    @Test
    fun `detekt gate resolves types, so the !! ban fires on a JVM project`() {
        build(
            """
            plugins {
                id("org.jetbrains.kotlin.jvm")
                id("binge.gates.detekt")
            }
            repositories { mavenCentral() }
            """.trimIndent(),
        )
        write("detekt.yml", "potential-bugs:\n  UnsafeCallOnNullableType:\n    active: true\n")
        write("src/main/kotlin/sample/Length.kt", "package sample\n\nfun length(text: String?): Int = text!!.length\n")

        val failing = runner("check", withKotlin = true).buildAndFail()

        assertTrue(failing.output.contains("UnsafeCallOnNullableType"), failing.output)

        write("src/main/kotlin/sample/Length.kt", "package sample\n\nfun length(text: String?): Int = text?.length ?: 0\n")
        runner("check", withKotlin = true).build()
    }

    private fun build(
        script: String,
        settings: String = "",
    ) {
        write("settings.gradle.kts", "rootProject.name = \"sample\"\n$settings\n")
        write("build.gradle.kts", script)
    }

    private fun write(
        path: String,
        text: String,
    ) {
        File(root, path).apply {
            parentFile.mkdirs()
            writeText(text)
        }
    }

    private fun runner(
        task: String,
        withKotlin: Boolean = false,
    ): GradleRunner =
        GradleRunner
            .create()
            .withProjectDir(root)
            .withPluginClasspath(
                PluginUnderTestMetadataReading.readImplementationClasspath() +
                    if (withKotlin) System.getProperty("testKitKotlin").split(File.pathSeparator).map(::File) else emptyList(),
            )
            .withArguments(task, "--stacktrace")
}
