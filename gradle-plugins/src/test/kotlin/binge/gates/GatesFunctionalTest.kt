package binge.gates

import org.gradle.testkit.runner.GradleRunner
import org.gradle.testkit.runner.TaskOutcome
import org.gradle.testkit.runner.internal.PluginUnderTestMetadataReading
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
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

    private fun baseConfigBuild(gate: String) =
        build(
            """
            plugins {
                id("org.jetbrains.kotlin.jvm")
                id("binge.gates.detekt")
            }
            $REPOSITORIES
            $gate
            """.trimIndent(),
        )

    @Test
    fun `detekt gate runs without parallel by default, and parallel = true turns it back on`() {
        val printer =
            """
            tasks.register("printParallel") {
                val flags = tasks.withType<dev.detekt.gradle.Detekt>().map { it.parallel }
                doLast { println("parallel=" + flags.joinToString { it.get().toString() }) }
            }
            """.trimIndent()
        build(
            """
            plugins {
                id("org.jetbrains.kotlin.jvm")
                id("binge.gates.detekt")
            }
            $REPOSITORIES
            $printer
            """.trimIndent(),
        )
        val byDefault = runner("printParallel", withKotlin = true).build()
        assertTrue(byDefault.output.contains("parallel=false"), byDefault.output)

        build(
            """
            plugins {
                id("org.jetbrains.kotlin.jvm")
                id("binge.gates.detekt")
            }
            $REPOSITORIES
            detektGate { parallel = true }
            $printer
            """.trimIndent(),
        )
        val on = runner("printParallel", withKotlin = true).build()
        assertTrue(on.output.contains("parallel=true"), on.output)
    }

    @Test
    fun `the base config is read only when asked for, and brings the shared rules`() {
        write("src/main/kotlin/sample/Todo.kt", "package sample\n\n// TODO fix this\nconst val X = 1\n")
        baseConfigBuild("")
        write("detekt.yml", "")
        runner("detekt", withKotlin = true).build()

        baseConfigBuild("detektGate { baseConfig = true }")
        val failing = runner("detekt", withKotlin = true).buildAndFail()

        assertTrue(failing.output.contains("ForbiddenComment"), failing.output)
    }

    @Test
    fun `the consumer's own file is read after the base and overrides it, and a list it sets replaces the base's without a clash`() {
        write("src/main/kotlin/sample/Todo.kt", "package sample\n\n// TODO fix this\nconst val X = 1\n")
        baseConfigBuild("detektGate { baseConfig = true }")
        write(
            "detekt.yml",
            "style:\n  ForbiddenComment:\n    active: false\n  MagicNumber:\n    excludes: ['**/Other.kt']\n",
        )

        runner("detekt", withKotlin = true).build()
    }

    // detekt prints the count and passes; the gate has to read that line, so a detekt that rewords it fails here
    // rather than silently turning the ratchet off in every consumer.
    @Test
    fun `detekt gate reports the compiler errors detekt prints, and holds them to allowedCompilerErrors`() {
        build(compilerErrorBuild(""))
        write("detekt.yml", "potential-bugs:\n  UnsafeCallOnNullableType:\n    active: true\n")
        // Outside the compiler's source set, so only detekt reads it: the build compiles, and detekt cannot resolve the symbol.
        write("detekt-src/Unresolved.kt", "val value = unresolvedSymbol()\n")

        val reported = runner("detekt", withKotlin = true).build().output

        val printed = Regex("""There (?:was|were) (\d+) compiler errors? found during analysis""").find(reported)
        assertTrue(printed != null, "detekt no longer prints its compiler-error line:\n$reported")
        val count = printed!!.groupValues[1].toInt()
        assertTrue(count > 0, reported)
        assertTrue(reported.contains("reported $count compiler error(s)"), reported)
        assertTrue(reported.contains("allowedCompilerErrors = $count"), reported)

        build(compilerErrorBuild("allowedCompilerErrors.set($count)"))
        val held = runner("detekt", withKotlin = true).build().output
        assertFalse(held.contains("reported $count compiler error(s)"), held)

        build(compilerErrorBuild("allowedCompilerErrors.set(${count - 1})"))
        val failing = runner("detekt", withKotlin = true).buildAndFail().output
        assertTrue(failing.contains("reported $count compiler error(s) but detektGate.allowedCompilerErrors is ${count - 1}"), failing)

        build(compilerErrorBuild("allowedCompilerErrors.set(${count + 3})"))
        val lowering = runner("detekt", withKotlin = true).build().output
        assertTrue(lowering.contains("Lower detektGate.allowedCompilerErrors to $count"), lowering)

        // Fixed: detekt prints nothing at zero, and the limit still set has to ask to be lowered to 0.
        write("detekt-src/Unresolved.kt", "const val VALUE = 1\n")
        val fixed = runner("detekt", withKotlin = true).build().output
        assertTrue(fixed.contains("Lower detektGate.allowedCompilerErrors to 0"), fixed)
    }

    private fun compilerErrorBuild(setting: String) =
        """
        plugins {
            id("org.jetbrains.kotlin.jvm")
            id("binge.gates.detekt")
        }
        $REPOSITORIES
        detektGate {
            sourceDirectory.set("detekt-src")
            $setting
        }
        """.trimIndent()

    // Without the compilation nothing is wired and the detekt task runs with an empty classpath: green, and the !! ban never fires.
    @Test
    fun `detekt gate fails loudly when the requested compilation does not exist, and names the ones that do`() {
        build(
            """
            plugins {
                id("org.jetbrains.kotlin.jvm")
                id("binge.gates.detekt")
            }
            $REPOSITORIES
            detektGate { typeResolutionCompilation.set("paidDebug") }
            """.trimIndent(),
        )
        write("detekt.yml", "potential-bugs:\n  UnsafeCallOnNullableType:\n    active: true\n")
        write("src/main/kotlin/sample/Length.kt", "package sample\n\nfun length(text: String?): Int = text!!.length\n")

        val result = runner("detekt", withKotlin = true).buildAndFail()

        assertTrue(result.output.contains("no Kotlin compilation named 'paidDebug'"), result.output)
        assertTrue(result.output.contains("'main'"), result.output)
        assertTrue(result.output.contains("typeResolutionCompilation"), result.output)
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

    // A Multiplatform module's production source is every `src/*Main`, and types resolve against the
    // jvm target's `main`, which holds `commonMain`. A `!!` in `commonTest` is out of scope.
    @Test
    fun `detekt gate reads every Multiplatform main source set with types, and never a test one`() {
        val sdk =
            checkNotNull(System.getenv("ANDROID_HOME") ?: System.getenv("ANDROID_SDK_ROOT")) {
                "This test needs an Android SDK: set ANDROID_HOME."
            }
        build(
            """
            plugins {
                id("org.jetbrains.kotlin.multiplatform")
                id("com.android.kotlin.multiplatform.library")
                id("binge.gates.detekt")
            }
            $REPOSITORIES
            kotlin {
                jvm()
                android {
                    namespace = "sample"
                    compileSdk = 37
                    minSdk = 26
                }
            }
            """.trimIndent(),
        )
        write("local.properties", "sdk.dir=${File(sdk).invariantSeparatorsPath}\n")
        write("detekt.yml", "potential-bugs:\n  UnsafeCallOnNullableType:\n    active: true\n")
        val banned = "package sample\n\nfun length(text: String?): Int = text!!.length\n"
        val clean = "package sample\n\nfun length(text: String?): Int = text?.length ?: 0\n"
        write("src/commonTest/kotlin/sample/Test.kt", banned.replace("length", "testLength"))
        write("src/jvmMain/kotlin/sample/Jvm.kt", "package sample\n\nfun jvmLength(text: String?): Int = text!!.length\n")
        write("src/commonMain/kotlin/sample/Length.kt", banned)

        val failing = runner("detekt", withKotlin = true, withAndroid = true).buildAndFail()

        assertTrue(failing.output.contains("UnsafeCallOnNullableType"), failing.output)
        assertTrue(failing.output.contains("commonMain"), failing.output)
        assertTrue(failing.output.contains("jvmMain"), failing.output)
        assertFalse(failing.output.contains("sample/Test.kt"), failing.output)

        write("src/commonMain/kotlin/sample/Length.kt", clean)
        write("src/jvmMain/kotlin/sample/Jvm.kt", "package sample\n\nfun jvmLength(text: String?): Int = text?.length ?: 0\n")
        runner("detekt", withKotlin = true, withAndroid = true).build()
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
    // stale, so the root check reads both runs and reports only the entry neither produces. A third
    // project without the plugin publishes no report, and is passed over.
    @Test
    fun `aggregate baseline staleness reads every project's findings against one root baseline`() {
        val module =
            """
            import org.gradle.api.file.RegularFileProperty

            plugins {
                id("org.jetbrains.kotlin.jvm")
                id("binge.gates.baseline-staleness")
            }
            $REPOSITORIES
            // Through the extension by name, not the type-safe `detektGate { }` accessor. Under Isolated Projects `first` and
            // `second` configure in parallel, and `second` has twice failed to see a class the plugin registers: once
            // `dev.detekt`, once the extension's type, which left `detektGate`'s lambda without `baselineFile`. This build does
            // not need the accessor. See #182, which stays open until about 50 clean runs show whether this was the cause.
            extensions.getByName("detektGate").withGroovyBuilder {
                (getProperty("baselineFile") as RegularFileProperty).set(layout.settingsDirectory.file("detekt-baseline.xml"))
            }
            """.trimIndent()
        // The root resolves every plugin the subprojects use, once, and they inherit it. Under Isolated Projects the
        // subprojects configure in parallel, and each looking the injected TestKit plugin up for itself has twice come
        // back "not found" (#327) or without a class the plugin registers (#182). A consumer declares them at the root
        // the same way, `apply false`, for the same reason.
        build(
            "plugins {\n" +
                "    id(\"binge.gates.baseline-staleness-aggregate\")\n" +
                "    id(\"org.jetbrains.kotlin.jvm\") apply false\n" +
                "    id(\"binge.gates.baseline-staleness\") apply false\n" +
                "}\n",
            settings = "include(\"first\", \"second\", \"docs\")")
        // Under Isolated Projects, as a large consumer builds: the root must not reach into a subproject's model.
        File(root, "gradle.properties").appendText("binge.gates.baseline-staleness.aggregate=true\norg.gradle.unsafe.isolated-projects=true\n")
        write("first/build.gradle.kts", module)
        write("second/build.gradle.kts", module)
        // A library's own variants must not be mistaken for a findings report.
        write("docs/build.gradle.kts", "plugins {\n    java\n}\n")
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

    // AGP compiles BuildConfig with javac, outside the Kotlin compilation's own output. detekt 2.x counts
    // every reference it cannot resolve as a compiler error, and stops applying the rules that need
    // types to that code, while the build still passes. So a read of BuildConfig must resolve.
    @Test
    fun `detekt gate resolves an Android module's BuildConfig`() {
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
                buildFeatures { buildConfig = true }
            }
            """.trimIndent(),
        )
        write("local.properties", "sdk.dir=${File(sdk).invariantSeparatorsPath}\n")
        write("detekt.yml", "potential-bugs:\n  UnsafeCallOnNullableType:\n    active: true\n")
        write("src/main/kotlin/sample/Flags.kt", "package sample\n\nfun isDebug(): Boolean = BuildConfig.DEBUG\n")

        val result = runner("detekt", withKotlin = true, withAndroid = true).build()

        assertFalse(result.output.contains("compiler errors"), result.output)
    }

    // An `internal` declaration in an excluded file is invisible to detekt: its compiled class is a binary dependency,
    // and `internal` stops at the module boundary. Every reference to it is a compiler error that blinds the type-resolved
    // rules for the caller, with a green build. Analysing the file and silencing its findings fixes both.
    @Test
    fun `suppressedPaths analyses a preview-data file so its internal symbols resolve, and reports nothing in it`() {
        previewDataProject()

        val before = runner("detekt", withKotlin = true).buildAndFail()
        assertTrue(Regex("""There (?:was|were) \d+ compiler errors? found""").containsMatchIn(before.output), before.output)

        previewDataProject(suppressed = true)

        val after = runner("detekt", withKotlin = true).buildAndFail()
        assertFalse(after.output.contains("compiler error"), after.output)
        assertTrue(after.output.contains("Use.kt") && after.output.contains("UnsafeCallOnNullableType"), after.output)
        assertFalse(after.output.contains("SamplePreviewData.kt"), after.output)
    }

    @Test
    fun `suppressedPaths refuses a rule set of the consumer's that carries its own excludes`() {
        previewDataProject(suppressed = true)
        write(
            "detekt.yml",
            "potential-bugs:\n  excludes: ['**/Other.kt']\n  UnsafeCallOnNullableType:\n    active: true\n",
        )

        val result = runner("detekt", withKotlin = true).buildAndFail()

        assertTrue(result.output.contains("sets `excludes` on the rule set(s) potential-bugs"), result.output)
    }

    // The shared fragment bans a raw Material block that the design system wraps. The Material functions are declared in
    // the fixture itself, so a call resolves without the Compose libraries, which is what ForbiddenMethodCall needs.
    @Test
    fun `the design-system fragment bans a raw Material import and call, names the wrapper, and leaves wrappers, the escape hatch and the design system alone`() {
        designSystemProject()
        write("src/main/kotlin/app/ImportsRaw.kt", "package app\n\nimport androidx.compose.material3.Scaffold\n\nfun screen() = Scaffold()\n")
        write("src/main/kotlin/app/CallsRaw.kt", "package app\n\nimport androidx.compose.material3.*\n\nfun other() = TextField()\n")
        write("src/main/kotlin/app/Qualified.kt", "package app\n\nfun third() = androidx.compose.material3.AlertDialog()\n")

        val failing = runner("detekt", withKotlin = true).buildAndFail()

        assertTrue(failing.output.contains("ImportsRaw.kt") && failing.output.contains("ForbiddenImport"), failing.output)
        assertTrue(failing.output.contains("Use BingeScreenScaffold instead of the raw Material Scaffold"), failing.output)
        assertTrue(failing.output.contains("CallsRaw.kt") && failing.output.contains("ForbiddenMethodCall"), failing.output)
        assertTrue(failing.output.contains("Use BingeTextField"), failing.output)
        assertTrue(failing.output.contains("Qualified.kt") && failing.output.contains("Use BingeConfirmDialog or BingeMessageDialog"), failing.output)
        assertTrue(failing.output.contains("design-system/docs/components.md"), failing.output)
        // The design system's own file is not reported, and neither is the declaration of the Material function.
        assertFalse(failing.output.contains("DesignSystemOwn.kt"), failing.output)
        assertFalse(failing.output.contains("Material.kt"), failing.output)
        assertFalse(failing.output.contains("Wrapper.kt"), failing.output)
        assertFalse(failing.output.contains("Reviewed.kt"), failing.output)

        File(root, "src/main/kotlin/app/ImportsRaw.kt").delete()
        File(root, "src/main/kotlin/app/CallsRaw.kt").delete()
        File(root, "src/main/kotlin/app/Qualified.kt").delete()
        runner("detekt", withKotlin = true).build()
    }

    // A consumer that already bans a call of its own (a list `ForbiddenMethodCall.methods`) must not have it replaced without
    // a word by a fragment that sets the same list: detekt replaces a list rather than merging it.
    @Test
    fun `a fragment that sets a list the consumer's own detekt yml sets is refused and names the list`() {
        designSystemProject(own = "style:\n  ForbiddenMethodCall:\n    active: true\n    methods:\n      - value: 'kotlin.runCatching'\n        reason: 'swallows cancellation'\n")

        val result = runner("detekt", withKotlin = true).buildAndFail()

        assertTrue(result.output.contains("style.ForbiddenMethodCall.methods"), result.output)
        assertTrue(result.output.contains("detekt.yml and design-system-call-bans.yml"), result.output)
    }

    @Test
    fun `the import fragment alone leaves the consumer's own method bans standing`() {
        designSystemProject(
            own = "style:\n  ForbiddenMethodCall:\n    active: true\n    methods:\n      - value: 'kotlin.runCatching'\n        reason: 'swallows cancellation'\n",
            fragments = listOf("design-system-bans.yml"),
        )
        write("src/main/kotlin/app/Catches.kt", "package app\n\nfun catches() = runCatching { 1 }\n")
        write("src/main/kotlin/app/ImportsRaw.kt", "package app\n\nimport androidx.compose.material3.Scaffold\n\nfun screen() = Scaffold()\n")

        val failing = runner("detekt", withKotlin = true).buildAndFail()

        assertFalse(failing.output.contains("checkDetektConfigClashes FAILED"), failing.output)
        assertTrue(failing.output.contains("Catches.kt") && failing.output.contains("swallows cancellation"), failing.output)
        assertTrue(failing.output.contains("ImportsRaw.kt") && failing.output.contains("Use BingeScreenScaffold"), failing.output)
    }

    // The rules carry their own `excludes`, and the suppressions layer puts `excludes` on the rule set. Both have to keep a
    // preview-data file out of the bans, or the fragment would report where every other style rule is silent.
    @Test
    fun `a suppressed path stays silent for the design-system bans too`() {
        designSystemProject(suppressed = true)
        write("src/main/kotlin/app/SamplePreviewData.kt", "package app\n\nimport androidx.compose.material3.Scaffold\n\nfun preview() = Scaffold()\n")

        runner("detekt", withKotlin = true).build()
    }

    /** A project that applies the gate with the fragments, the Material functions they ban, a wrapper, a reviewed exception and a file of the design system's. */
    private fun designSystemProject(
        own: String = "",
        fragments: List<String> = listOf("design-system-bans.yml", "design-system-call-bans.yml"),
        suppressed: Boolean = false,
    ) {
        val files =
            fragments.map {
                File(System.getProperty("user.dir"), "../detekt/$it").canonicalFile.also { file -> assertTrue(file.isFile, "the fragment is at $file") }
            }
        build(
            """
            plugins {
                id("org.jetbrains.kotlin.jvm")
                id("binge.gates.detekt")
            }
            $REPOSITORIES
            // Only the fragments' rules, so what the fixture files do for detekt's defaults (naming, empty blocks) is not under test.
            detektGate {
                buildUponDefaultConfig.set(false)
                ${files.joinToString("\n                ") { """additionalConfigs.from(file("${it.invariantSeparatorsPath}"))""" }}
                ${if (suppressed) """suppressedPaths.set(listOf("**/*PreviewData.kt"))""" else ""}
            }
            """.trimIndent(),
        )
        write("detekt.yml", own)
        write(
            "src/main/kotlin/androidx/compose/material3/Material.kt",
            "@file:Suppress(\"ForbiddenMethodCall\")\npackage androidx.compose.material3\n\n" +
                listOf("Scaffold", "TextField", "AlertDialog").joinToString("\n") { "fun $it() {}" } + "\n",
        )
        write("src/main/kotlin/app/Wrapper.kt", "package app\n\nfun BingeScreenScaffold() {}\n\nfun usesWrapper() = BingeScreenScaffold()\n")
        write(
            "src/main/kotlin/app/Reviewed.kt",
            "@file:Suppress(\"ForbiddenImport\", \"ForbiddenMethodCall\")\n\npackage app\n\n" +
                "// A reviewed exception: the wrapper does not take a custom slot here.\nimport androidx.compose.material3.Scaffold\n\nfun reviewed() = Scaffold()\n",
        )
        write(
            "src/main/kotlin/design-system/DesignSystemOwn.kt",
            "package ds\n\nimport androidx.compose.material3.Scaffold\n\nfun own() = Scaffold()\n",
        )
    }

    /** Three `internal` fixtures in a preview-data file, a caller that reads each, and a `!!` on each side of the boundary. */
    private fun previewDataProject(suppressed: Boolean = false) {
        build(
            """
            plugins {
                id("org.jetbrains.kotlin.jvm")
                id("binge.gates.detekt")
            }
            $REPOSITORIES
            ${if (suppressed) """detektGate { suppressedPaths.set(listOf("**/*PreviewData.kt")) }""" else ""}
            """.trimIndent(),
        )
        write("detekt.yml", "potential-bugs:\n  UnsafeCallOnNullableType:\n    active: true\n")
        write(
            "src/main/kotlin/sample/SamplePreviewData.kt",
            "package sample\n\ninternal val previewA: String? = \"a\"\n\ninternal val previewB: String? = \"b\"\n\n" +
                "internal fun previewC(): String? = \"c\"\n\ninternal fun risky(text: String?): Int = text!!.length\n",
        )
        write(
            "src/main/kotlin/sample/Use.kt",
            "package sample\n\nfun use(): Int = previewA!!.length + previewB.orEmpty().length + (previewC() ?: \"\").length\n",
        )
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
