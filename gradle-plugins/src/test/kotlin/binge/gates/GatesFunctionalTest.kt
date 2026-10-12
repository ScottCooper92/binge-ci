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
            $REPOSITORIES
            """.trimIndent(),
        )
        assertTheBanFires("check", withKotlin = true)
    }

    // The same proof on an Android library, where the gate resolves types against a variant's
    // compilation rather than `main`: AGP's compilations exist only after evaluation, and the
    // classpath comes from the variant's compile task. The SDK is the runner's own.
    @Test
    fun `detekt gate resolves types on an Android project, against the debug compilation`() {
        val sdk =
            checkNotNull(System.getenv("ANDROID_HOME") ?: System.getenv("ANDROID_SDK_ROOT")) {
                "This test needs an Android SDK: set ANDROID_HOME."
            }
        build(
            """
            plugins {
                id("com.android.library")
                id("binge.gates.detekt")
            }
            $REPOSITORIES
            android {
                namespace = "sample"
                compileSdk = 37
                defaultConfig { minSdk = 26 }
            }
            detektGate { typeResolutionCompilation.set("debug") }
            """.trimIndent(),
        )
        write("local.properties", "sdk.dir=${File(sdk).invariantSeparatorsPath}\n")

        assertTheBanFires("detekt", withKotlin = true, withAndroid = true)
    }

    /** A `!!` fails [task] naming the rule, and the same file without it passes. */
    private fun assertTheBanFires(
        task: String,
        withKotlin: Boolean,
        withAndroid: Boolean = false,
    ) {
        write("detekt.yml", "potential-bugs:\n  UnsafeCallOnNullableType:\n    active: true\n")
        write("src/main/kotlin/sample/Length.kt", "package sample\n\nfun length(text: String?): Int = text!!.length\n")

        val failing = runner(task, withKotlin, withAndroid).buildAndFail()

        assertTrue(failing.output.contains("UnsafeCallOnNullableType"), failing.output)

        write("src/main/kotlin/sample/Length.kt", "package sample\n\nfun length(text: String?): Int = text?.length ?: 0\n")
        runner(task, withKotlin, withAndroid).build()
    }

    private companion object {
        // Google's mirror of Maven Central first, as this build's own settings do: Central rate-limits
        // shared runners, and Gradle treats a 429 as a failure rather than a miss.
        const val REPOSITORIES =
            "repositories {\n" +
                "    maven(\"https://maven-central.storage-download.googleapis.com/maven2/\")\n" +
                "    google()\n" +
                "    mavenCentral()\n" +
                "}"
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
        withAndroid: Boolean = false,
    ): GradleRunner =
        GradleRunner
            .create()
            .withProjectDir(root)
            .withPluginClasspath(
                PluginUnderTestMetadataReading.readImplementationClasspath() +
                    (if (withKotlin) classpath("testKitKotlin") else emptyList()) +
                    (if (withAndroid) classpath("testKitAndroid") else emptyList()),
            )
            .withArguments(task, "--stacktrace")

    private fun classpath(property: String): List<File> = System.getProperty(property).split(File.pathSeparator).map(::File)
}
