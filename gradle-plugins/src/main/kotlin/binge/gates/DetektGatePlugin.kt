package binge.gates

import dev.detekt.gradle.Detekt
import dev.detekt.gradle.DetektCreateBaselineTask
import dev.detekt.gradle.plugin.DetektPlugin
import org.gradle.api.GradleException
import org.gradle.api.Plugin
import org.gradle.api.Project
import org.gradle.api.file.ConfigurableFileCollection
import org.gradle.api.file.FileTree
import org.gradle.api.file.RegularFile
import org.gradle.api.file.RegularFileProperty
import org.gradle.api.provider.ListProperty
import org.gradle.api.provider.Property
import org.gradle.api.provider.Provider
import java.io.File

internal const val DETEKT_WITHOUT_BASELINE = "detektWithoutBaseline"

/** Configuration for `binge.gates.detekt`. */
abstract class DetektGateExtension {
    /** The detekt config. Defaults to `detekt.yml` in the settings directory. */
    abstract val configFile: RegularFileProperty

    /**
     * Config files read after [configFile], such as a shared fragment a consumer extends from its `binge-ci` submodule.
     * detekt reads a later file over an earlier one key by key, and a list is replaced rather than merged, so a fragment owns
     * the lists it sets. Empty by default, which changes nothing.
     */
    abstract val additionalConfigs: ConfigurableFileCollection

    /** The baseline. Unset means no baseline; a set file that does not exist yet is ignored until it does. */
    abstract val baselineFile: RegularFileProperty

    /** A project holding custom rules, such as `:detekt-rules`, added to `detektPlugins`. Unset means none. */
    abstract val customRulesProject: Property<String>

    /**
     * The source detekt reads, relative to the project. Unset means `src/main`, or on a Kotlin Multiplatform project every
     * `Main` source set directory under `src`, such as `src/commonMain`, and never a test one. Setting it wins on either.
     */
    abstract val sourceDirectory: Property<String>

    /** Globs left out of [sourceDirectory]. Defaults to every file named `…PreviewData.kt`, preview tooling rather than logic. */
    abstract val excludes: ListProperty<String>

    /**
     * Globs analysed but never reported on. An excluded file is not analysed, so an `internal` declaration in it is
     * invisible to detekt (its compiled class is a binary dependency, and `internal` stops at the module boundary) and every
     * reference to it counts as a compiler error, which blinds the type-resolved rules for the code that calls it. A glob
     * listed here is analysed, so it resolves, and findings reported in it are dropped through the rule sets' `excludes`.
     * It wins over [excludes]: a glob in both is analysed. Empty by default, which changes nothing.
     */
    abstract val suppressedPaths: ListProperty<String>

    /**
     * Rule set ids beyond detekt's own that [suppressedPaths] also silences, such as a custom ruleset or the community
     * Compose rules. A rule set not named here reports on a suppressed path.
     */
    abstract val suppressedRuleSets: ListProperty<String>

    /** Defaults to `17`. */
    abstract val jvmTarget: Property<String>

    /**
     * Loads the shared comment rules (`BannerComment`, `ConsecutiveInlineComments`, `DeclarationCommentShouldBeKDoc`,
     * `KDocLength`) onto the detekt run. Defaults to false: they are inactive until a config file turns them on under
     * `binge:`, and a repository that has not yet taken their findings should not meet them by surprise.
     */
    abstract val commentRules: Property<Boolean>

    /** Defaults to true, so the config file records only deviations from detekt's defaults. */
    abstract val buildUponDefaultConfig: Property<Boolean>

    /** Defaults to true. */
    abstract val parallel: Property<Boolean>

    /**
     * The Kotlin compilation whose classpath detekt resolves types against. Defaults to `main` on a
     * JVM project, `debug` on an Android one and `main` of the `jvm` target (else the Android target) on a Multiplatform one. A name that matches no compilation, as a flavoured Android module has
     * with `debug`, fails every detekt task and lists the compilations that exist, since the task would otherwise run
     * without type resolution and stay green.
     */
    abstract val typeResolutionCompilation: Property<String>

    /**
     * How many "compiler errors found during analysis" detekt may report in this project. Unset means report only: a
     * warning naming the count. Once set, a higher count fails the detekt task and a lower one says to lower it, so the
     * number can only go down. A compiler error is a symbol detekt could not resolve, and the type-resolved rules (the
     * `!!` ban) are blind to the code that depends on it.
     */
    abstract val allowedCompilerErrors: Property<Int>
}

/**
 * Applies detekt pinned to production source, with type resolution and an optional baseline.
 *
 * A detekt task carries no classpath by default, and without one every rule that needs type
 * resolution loads and silently never fires; `UnsafeCallOnNullableType`, the `!!` ban, is the one
 * that hurts. So the compile classpath of one Kotlin compilation is wired onto every detekt task.
 */
class DetektGatePlugin : Plugin<Project> {
    override fun apply(project: Project) {
        // detekt 2.x reads the Kotlin plugin's types as it applies, and dies on a bare
        // NoClassDefFoundError without them. Saying why is the whole of this check.
        if (!kotlinGradlePluginVisible()) {
            throw GradleException(
                "binge.gates.detekt needs the Kotlin Gradle plugin on the build classpath: detekt 2.x will not apply without it.",
            )
        }
        // By class, not by id. An id is looked up in the applying project's plugin registry, and
        // under Isolated Projects a subproject configured in parallel could intermittently miss it (#182).
        project.pluginManager.apply(DetektPlugin::class.java)

        val gate = project.extensions.create("detektGate", DetektGateExtension::class.java)
        gate.configFile.convention(project.layout.settingsDirectory.file("detekt.yml"))
        gate.excludes.convention(listOf("**/*PreviewData.kt"))
        gate.suppressedPaths.convention(emptyList())
        gate.suppressedRuleSets.convention(emptyList())
        gate.jvmTarget.convention("17")
        gate.commentRules.convention(false)
        gate.buildUponDefaultConfig.convention(true)
        gate.parallel.convention(true)

        project.configurations.named("detektPlugins") {
            dependencies.addLater(gate.customRulesProject.map { project.dependencies.project(mapOf("path" to it)) })
            // The rules ship in this plugin's own jar, so detekt loads them from where the plugin itself was loaded.
            dependencies.addLater(
                gate.commentRules.map { on ->
                    if (on) project.dependencies.create(project.files(commentRulesLocation())) else null
                },
            )
        }

        // The extension's values are read when a task is configured, which is after the build script
        // has set them. The tasks are configured rather than detekt's extension, so that a task registered
        // outside it, such as the baseline-staleness run, gets the same settings.
        val suppressions = DetektSuppressions.register(project, gate)
        // A fragment that sets a list the consumer's own config sets would replace it without a word, so it is refused.
        val clashes =
            project.tasks.register("checkDetektConfigClashes", CheckDetektConfigClashesTask::class.java) {
                val extra = gate.additionalConfigs
                configs.from(gate.configFile, extra)
                onlyIf { !extra.isEmpty }
            }

        project.tasks.withType(Detekt::class.java).configureEach {
            dependsOn(clashes)
            setSource(project.productionSource(gate))
            config.setFrom(gate.configFile)
            config.from(gate.additionalConfigs)
            // After the consumer's own file: detekt reads a later config file over an earlier one, so the layer's `excludes`
            // would replace a rule set's own. The task refuses that clash rather than let it through.
            if (gate.suppressedPaths.get().isNotEmpty()) config.from(suppressions.flatMap { it.output })
            buildUponDefaultConfig.set(gate.buildUponDefaultConfig)
            parallel.set(gate.parallel)
            jvmTarget.set(gate.jvmTarget)
            // The baseline-staleness task must see every finding, and sets its own reports.
            if (name == DETEKT_WITHOUT_BASELINE) return@configureEach
            baseline.set(project.existingFile(gate.baselineFile))
            reports {
                checkstyle.required.set(false)
                sarif.required.set(false)
                markdown.required.set(false)
            }
        }
        project.tasks.withType(DetektCreateBaselineTask::class.java).configureEach {
            dependsOn(clashes)
            setSource(project.productionSource(gate))
            config.setFrom(gate.configFile)
            config.from(gate.additionalConfigs)
            if (gate.suppressedPaths.get().isNotEmpty()) config.from(suppressions.flatMap { it.output })
            buildUponDefaultConfig.set(gate.buildUponDefaultConfig)
            parallel.set(gate.parallel)
            jvmTarget.set(gate.jvmTarget)
            if (gate.baselineFile.isPresent) baseline.set(gate.baselineFile)
        }

        // After evaluation, for two reasons. Android's variant compilations do not exist yet when the
        // Kotlin plugin applies, and a JVM project's `main` exists before the build script can name
        // another. configureEach inside still catches compilations created later.
        project.afterEvaluate {
            KotlinTypeResolution.wire(project, gate.typeResolutionCompilation.orNull)
        }
        CompilerErrorRatchet.wire(project, gate.allowedCompilerErrors)
    }
}

/** Pinned with `setSource` rather than exclude patterns, so a test or generated source set never leaks in. */
private fun Project.productionSource(gate: DetektGateExtension): FileTree {
    val excluded = gate.excludes.get() - gate.suppressedPaths.get().toSet()
    val explicit = gate.sourceDirectory.orNull
    val directories =
        when {
            explicit != null -> listOf(explicit)
            isKotlinMultiplatform() ->
                // `src/commonMain`, `src/jvmMain`, `src/androidMain`; `…Test` and `…TestFixtures`-style sets never end in `Main`.
                (layout.projectDirectory.dir("src").asFile.listFiles().orEmpty())
                    .filter { it.isDirectory && it.name.endsWith("Main") }
                    .map { "src/${it.name}" }
                    .sorted()
            else -> listOf("src/main")
        }
    return directories
        .map { dir ->
            fileTree(dir) {
                include("**/*.kt")
                exclude(excluded)
            }
        }.fold(files().asFileTree) { all, tree -> all + tree }
}

private fun Project.existingFile(file: RegularFileProperty): Provider<RegularFile> =
    layout.file(file.map { it.asFile }.filter { it.exists() })

/** The Kotlin plugin is compileOnly here, so its types may only be touched once it is known to load. */
private fun kotlinGradlePluginVisible(): Boolean =
    runCatching {
        Class.forName("org.jetbrains.kotlin.gradle.dsl.KotlinProjectExtension", false, DetektGatePlugin::class.java.classLoader)
    }.isSuccess

/** Where this plugin was loaded from. The rules only load from its jar: a class directory has no service file. */
private fun commentRulesLocation(): File = File(DetektGatePlugin::class.java.protectionDomain.codeSource.location.toURI())
