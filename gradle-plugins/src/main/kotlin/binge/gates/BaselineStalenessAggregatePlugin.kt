package binge.gates

import org.gradle.api.GradleException
import org.gradle.api.Plugin
import org.gradle.api.Project
import org.gradle.api.file.RegularFileProperty

/** Configuration for `binge.gates.baseline-staleness-aggregate`. */
abstract class BaselineStalenessAggregateExtension {
    /** The baseline every project shares. Defaults to `detekt-baseline.xml` in the root project. */
    abstract val baselineFile: RegularFileProperty
}

/**
 * Registers a root `checkBaselineStaleness` that reads one baseline shared by several projects.
 *
 * Applied to the root project, for a build whose projects point `detektGate.baselineFile` at one
 * root file. The per-project check cannot judge that file: each project sees only its own findings,
 * so every entry another project owns looks stale. This one compares the baseline with the union of
 * every project's findings, and reports only the entries no project produces any more.
 *
 * It takes over each subproject that applies `binge.gates.baseline-staleness`. That project's own
 * check is skipped, and its baseline-free run is gated on the root baseline instead of its own.
 * A project that does not apply that plugin is not read, so its findings cannot keep an entry alive.
 */
class BaselineStalenessAggregatePlugin : Plugin<Project> {
    override fun apply(project: Project) {
        if (project != project.rootProject) {
            throw GradleException("binge.gates.baseline-staleness-aggregate applies to the root project only, not ${project.path}.")
        }
        if (project.pluginManager.hasPlugin(BASELINE_STALENESS_ID)) {
            throw GradleException(
                "The root project applies both baseline-staleness plugins. Apply $BASELINE_STALENESS_ID to the projects " +
                    "that run detekt, and binge.gates.baseline-staleness-aggregate to the root.",
            )
        }
        val aggregate = project.extensions.create("baselineStalenessAggregate", BaselineStalenessAggregateExtension::class.java)
        aggregate.baselineFile.convention(project.layout.projectDirectory.file("detekt-baseline.xml"))
        val hasBaseline = aggregate.baselineFile.map { it.asFile.exists() }.orElse(false)
        val reports = project.objects.fileCollection()

        project.subprojects {
            val subproject = this
            pluginManager.withPlugin(BASELINE_STALENESS_ID) {
                val run = subproject.tasks.named(DETEKT_WITHOUT_BASELINE)
                run.configure { setOnlyIf("the root detekt baseline exists") { hasBaseline.get() } }
                subproject.tasks.named(CHECK_BASELINE_STALENESS).configure {
                    setOnlyIf("the root aggregate check reads this project's findings") { false }
                }
                reports.from(subproject.layout.buildDirectory.file(NO_BASELINE_REPORT))
                reports.builtBy(run)
            }
        }

        val check =
            project.tasks.register(CHECK_BASELINE_STALENESS, CheckBaselineStalenessTask::class.java) {
                group = "verification"
                description = "Fails when the shared detekt baseline holds an entry no project produces any more."
                baselineFile.set(aggregate.baselineFile)
                reportFiles.from(reports)
                onlyIf("the root detekt baseline exists") { hasBaseline.get() }
            }
        project.wireIntoCheck(check)
    }

    private companion object {
        const val BASELINE_STALENESS_ID = "binge.gates.baseline-staleness"
    }
}
