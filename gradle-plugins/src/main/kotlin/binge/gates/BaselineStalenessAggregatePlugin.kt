package binge.gates

import org.gradle.api.GradleException
import org.gradle.api.Plugin
import org.gradle.api.Project
import org.gradle.api.attributes.Attribute
import org.gradle.api.attributes.AttributeContainer
import org.gradle.api.attributes.Category
import org.gradle.api.file.RegularFileProperty
import org.gradle.api.model.ObjectFactory
import org.gradle.api.provider.Provider

/** The Gradle property that puts every project in the build into aggregate mode. */
internal const val AGGREGATE_PROPERTY = "binge.gates.baseline-staleness.aggregate"

internal const val BASELINE_REPORT_ELEMENTS = "detektBaselineReportElements"

private const val BASELINE_REPORTS = "detektBaselineReports"
private val BASELINE_REPORT = Attribute.of("binge.baseline-report", String::class.java)

/**
 * The variant a project's baseline-free report is published as. The category keeps it apart from a
 * library's own variants, which would otherwise match a request that only names the custom attribute.
 */
internal fun AttributeContainer.baselineReportAttributes(objects: ObjectFactory) {
    attribute(Category.CATEGORY_ATTRIBUTE, objects.named(Category::class.java, "binge-baseline-report"))
    attribute(BASELINE_REPORT, "detekt-no-baseline")
}

internal fun Project.aggregateMode(): Provider<Boolean> =
    providers.gradleProperty(AGGREGATE_PROPERTY).map { it.toBoolean() }.orElse(false)

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
 * It never reads another project's model, so it holds under Isolated Projects. Each project that
 * applies `binge.gates.baseline-staleness` publishes its baseline-free report as a variant, and the
 * root resolves that variant from every subproject. A project without the plugin publishes none, is
 * passed over, and so its findings cannot keep an entry alive. The Gradle property
 * [AGGREGATE_PROPERTY], set for the whole build, is what tells each project to skip its own check.
 */
class BaselineStalenessAggregatePlugin : Plugin<Project> {
    override fun apply(project: Project) {
        if (project != project.rootProject) {
            throw GradleException("binge.gates.baseline-staleness-aggregate applies to the root project only, not ${project.path}.")
        }
        if (!project.aggregateMode().get()) {
            throw GradleException(
                "binge.gates.baseline-staleness-aggregate needs $AGGREGATE_PROPERTY=true in the root gradle.properties. " +
                    "It is what tells each project to leave the shared baseline to the root check.",
            )
        }
        val aggregate = project.extensions.create("baselineStalenessAggregate", BaselineStalenessAggregateExtension::class.java)
        aggregate.baselineFile.convention(project.layout.projectDirectory.file("detekt-baseline.xml"))
        val hasBaseline = aggregate.baselineFile.map { it.asFile.exists() }.orElse(false)

        val declared =
            project.configurations.dependencyScope(BASELINE_REPORTS) {
                // A project's path is its identity, not its model, so reading it is allowed.
                project.subprojects.forEach { dependencies.add(project.dependencies.project(mapOf("path" to it.path))) }
            }
        val reports =
            project.configurations.resolvable("${BASELINE_REPORTS}Path") {
                extendsFrom(declared.get())
                attributes { baselineReportAttributes(project.objects) }
            }
        // Lenient, because a project that does not apply the per-project plugin has no such variant.
        val reportFiles = reports.map { it.incoming.artifactView { lenient(true) }.files }

        val check =
            project.tasks.register(CHECK_BASELINE_STALENESS, CheckBaselineStalenessTask::class.java) {
                group = "verification"
                description = "Fails when the shared detekt baseline holds an entry no project produces any more."
                baselineFile.set(aggregate.baselineFile)
                this.reportFiles.from(reportFiles)
                onlyIf("the root detekt baseline exists") { hasBaseline.get() }
            }
        project.wireIntoCheck(check)
    }
}
