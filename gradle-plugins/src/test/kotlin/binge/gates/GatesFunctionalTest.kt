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

        val rules = runner("printRules", withKotlin = true).build()
        val staleness = runner("checkBaselineStaleness", withKotlin = true).build()

        assertTrue(rules.output.contains("rules=rules"), rules.output)
        assertEquals(TaskOutcome.SKIPPED, staleness.task(":detektWithoutBaseline")?.outcome, staleness.output)
        assertEquals(TaskOutcome.SKIPPED, staleness.task(":checkBaselineStaleness")?.outcome, staleness.output)
    }

    // No Kotlin plugin on this fixture's classpath is the non-Kotlin consumer, tested on purpose.
    @Test
    fun `detekt gate says why it cannot apply without the Kotlin Gradle plugin`() {
        build("plugins { id(\"binge.gates.detekt\") }")

        val result = runner("help").buildAndFail()

        assertTrue(result.output.contains("needs the Kotlin Gradle plugin on the build classpath"), result.output)
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

    // End to end against detekt's own output: the baseline it writes and the report it emits are the
    // two formats staleness parses, and both changed between detekt majors.
    @Test
    fun `baseline staleness passes on a fresh baseline and fails once its finding is fixed`() {
        build(
            """
            plugins {
                id("org.jetbrains.kotlin.jvm")
                id("binge.gates.baseline-staleness")
            }
            $REPOSITORIES
            detektGate { baselineFile.set(layout.projectDirectory.file("detekt-baseline.xml")) }
            """.trimIndent(),
        )
        write("detekt.yml", "potential-bugs:\n  UnsafeCallOnNullableType:\n    active: true\n")
        write("src/main/kotlin/sample/Length.kt", "package sample\n\nfun length(text: String?): Int = text!!.length\n")

        runner("detektBaseline", withKotlin = true).build()
        assertTrue(File(root, "detekt-baseline.xml").readText().contains("UnsafeCallOnNullableType"))
        runner("check", withKotlin = true).build()

        write("src/main/kotlin/sample/Length.kt", "package sample\n\nfun length(text: String?): Int = text?.length ?: 0\n")
        val stale = runner("checkBaselineStaleness", withKotlin = true).buildAndFail()

        assertTrue(stale.output.contains("UnsafeCallOnNullableType in Length.kt - baselined 1, reported 0"), stale.output)
    }

    // Two projects share one root baseline. Each one's own check would read the other's entry as
    // stale, so the root check reads both runs and reports only the entry neither produces.
    @Test
    fun `aggregate baseline staleness reads every project's findings against one root baseline`() {
        val module =
            """
            plugins {
                id("org.jetbrains.kotlin.jvm")
                id("binge.gates.baseline-staleness")
            }
            $REPOSITORIES
            detektGate { baselineFile.set(rootProject.layout.projectDirectory.file("detekt-baseline.xml")) }
            """.trimIndent()
        build("plugins {\n    id(\"binge.gates.baseline-staleness-aggregate\")\n}\n", settings = "include(\"first\", \"second\")")
        write("first/build.gradle.kts", module)
        write("second/build.gradle.kts", module)
        write("detekt.yml", "potential-bugs:\n  UnsafeCallOnNullableType:\n    active: true\n")
        write("first/src/main/kotlin/sample/Length.kt", "package sample\n\nfun length(text: String?): Int = text!!.length\n")
        write("second/src/main/kotlin/sample/Width.kt", "package sample\n\nfun width(text: String?): Int = text!!.length\n")

        // detekt writes one project's baseline at a time, so the shared one is the two spliced together.
        val baseline = File(root, "detekt-baseline.xml")
        runner(":first:detektBaseline", withKotlin = true).build()
        val first = baseline.readText()
        runner(":second:detektBaseline", withKotlin = true).build()
        val ids = Regex("<ID>[^<]+</ID>").findAll(baseline.readText()).joinToString("") { it.value }
        baseline.writeText(first.replace("</CurrentIssues>", "$ids</CurrentIssues>"))
        assertTrue(baseline.readText().contains("Length.kt") && baseline.readText().contains("Width.kt"), baseline.readText())

        val fresh = runner("check", withKotlin = true).build()
        assertEquals(TaskOutcome.SKIPPED, fresh.task(":first:checkBaselineStaleness")?.outcome)
        assertEquals(TaskOutcome.SUCCESS, fresh.task(":checkBaselineStaleness")?.outcome)

        write("second/src/main/kotlin/sample/Width.kt", "package sample\n\nfun width(text: String?): Int = text?.length ?: 0\n")
        val stale = runner("check", withKotlin = true).buildAndFail()

        assertTrue(stale.output.contains("UnsafeCallOnNullableType in Width.kt - baselined 1, reported 0"), stale.output)
        assertTrue(stale.output.contains("holds 1 entry"), stale.output)
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
        // The memory every consumer gives its own build. detekt 2.x runs the Kotlin analysis API in the
        // daemon, and TestKit reuses one daemon across fixtures, so Gradle's default 384 MiB of metaspace
        // runs out partway through the suite.
        write("gradle.properties", "org.gradle.jvmargs=-Xmx1g -XX:MaxMetaspaceSize=1g\n")
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
