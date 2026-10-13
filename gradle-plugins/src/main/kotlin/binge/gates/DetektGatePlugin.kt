package binge.gates

import dev.detekt.gradle.Detekt
import dev.detekt.gradle.DetektCreateBaselineTask
import dev.detekt.gradle.plugin.DetektPlugin
import org.gradle.api.GradleException
import org.gradle.api.Plugin
import org.gradle.api.Project
import org.gradle.api.file.FileTree
import org.gradle.api.file.RegularFile
import org.gradle.api.file.RegularFileProperty
import org.gradle.api.provider.ListProperty
import org.gradle.api.provider.Property
import org.gradle.api.provider.Provider

internal const val DETEKT_WITHOUT_BASELINE = "detektWithoutBaseline"

/** Configuration for `binge.gates.detekt`. */
abstract class DetektGateExtension {
    /** The detekt config. Defaults to `detekt.yml` in the settings directory. */
    abstract val configFile: RegularFileProperty

    /** The baseline. Unset means no baseline; a set file that does not exist yet is ignored until it does. */
    abstract val baselineFile: RegularFileProperty

    /** A project holding custom rules, such as `:detekt-rules`, added to `detektPlugins`. Unset means none. */
    abstract val customRulesProject: Property<String>

    /** The source detekt reads, relative to the project. Defaults to `src/main`. */
    abstract val sourceDirectory: Property<String>

    /** Globs left out of [sourceDirectory]. Defaults to every file named `…PreviewData.kt`, preview tooling rather than logic. */
    abstract val excludes: ListProperty<String>

    /** Defaults to `17`. */
    abstract val jvmTarget: Property<String>

    /** Defaults to true, so the config file records only deviations from detekt's defaults. */
    abstract val buildUponDefaultConfig: Property<Boolean>

    /** Defaults to true. */
    abstract val parallel: Property<Boolean>

    /**
     * The Kotlin compilation whose classpath detekt resolves types against. Defaults to `main` on a
     * JVM project and `debug` on an Android one.
     */
    abstract val typeResolutionCompilation: Property<String>
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
        gate.sourceDirectory.convention("src/main")
        gate.excludes.convention(listOf("**/*PreviewData.kt"))
        gate.jvmTarget.convention("17")
        gate.buildUponDefaultConfig.convention(true)
        gate.parallel.convention(true)

        project.configurations.named("detektPlugins") {
            dependencies.addLater(gate.customRulesProject.map { project.dependencies.project(mapOf("path" to it)) })
        }

        // The extension's values are read when a task is configured, which is after the build script
        // has set them. The tasks are configured rather than detekt's extension, so that a task registered
        // outside it, such as the baseline-staleness run, gets the same settings.
        project.tasks.withType(Detekt::class.java).configureEach {
            setSource(project.productionSource(gate))
            config.setFrom(gate.configFile)
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
            setSource(project.productionSource(gate))
            config.setFrom(gate.configFile)
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
    }
}

/** Pinned with `setSource` rather than exclude patterns, so a test or generated source set never leaks in. */
private fun Project.productionSource(gate: DetektGateExtension): FileTree =
    fileTree(gate.sourceDirectory.get()) {
        include("**/*.kt")
        exclude(gate.excludes.get())
    }

private fun Project.existingFile(file: RegularFileProperty): Provider<RegularFile> =
    layout.file(file.map { it.asFile }.filter { it.exists() })

/** The Kotlin plugin is compileOnly here, so its types may only be touched once it is known to load. */
private fun kotlinGradlePluginVisible(): Boolean =
    runCatching {
        Class.forName("org.jetbrains.kotlin.gradle.dsl.KotlinProjectExtension", false, DetektGatePlugin::class.java.classLoader)
    }.isSuccess
