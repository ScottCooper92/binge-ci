package binge.gates

import dev.detekt.gradle.Detekt
import org.gradle.api.Plugin
import org.gradle.api.Project
import org.gradle.api.file.RegularFile

internal const val NO_BASELINE_REPORT = "reports/detekt/no-baseline.xml"
internal const val CHECK_BASELINE_STALENESS = "checkBaselineStaleness"

/**
 * Registers `checkBaselineStaleness`, wired into `check`, and the baseline-free detekt run it reads.
 *
 * Applies `binge.gates.detekt` and reads its baseline, config and source, so the two runs cannot
 * disagree about which rules are on. With no baseline set, or none on disk, both tasks skip.
 *
 * This is the per-project mode: each project's baseline is checked against that project's findings.
 * Where several projects share one baseline, [BaselineStalenessAggregatePlugin] at the root checks it
 * against all of them instead. The Gradle property [AGGREGATE_PROPERTY] turns that on, and then this
 * project's own check skips, and the baseline-free report is published as an outgoing variant, which
 * is how the root reads it without touching this project's model.
 */
class BaselineStalenessPlugin : Plugin<Project> {
    override fun apply(project: Project) {
        project.pluginManager.apply(DetektGatePlugin::class.java)
        val gate = project.extensions.getByType(DetektGateExtension::class.java)
        val report = project.layout.buildDirectory.file(NO_BASELINE_REPORT)
        val hasBaseline = gate.baselineFile.map { it.asFile.exists() }.orElse(false)
        val aggregated = project.aggregateMode()

        // Findings are expected here, so it never fails on its own.
        val withoutBaseline =
            project.tasks.register(DETEKT_WITHOUT_BASELINE, Detekt::class.java) {
                description = "Runs detekt with no baseline applied, for checkBaselineStaleness."
                ignoreFailures.set(true)
                baseline.set(null as RegularFile?)
                reports {
                    checkstyle.required.set(true)
                    checkstyle.outputLocation.set(report)
                    html.required.set(false)
                    sarif.required.set(false)
                    markdown.required.set(false)
                }
                onlyIf("a detekt baseline exists") { hasBaseline.get() }
            }

        val check =
            project.tasks.register(CHECK_BASELINE_STALENESS, CheckBaselineStalenessTask::class.java) {
                group = "verification"
                description = "Fails when the detekt baseline holds an entry the code no longer produces."
                dependsOn(withoutBaseline)
                baselineFile.set(gate.baselineFile)
                reportFiles.from(report)
                onlyIf("a detekt baseline exists") { hasBaseline.get() }
                onlyIf("the root aggregate check reads this project's findings") { !aggregated.get() }
            }
        project.wireIntoCheck(check)

        // Only in aggregate mode, so a build that never resolves it carries no extra variant for
        // another plugin's resolution to weigh.
        if (aggregated.get()) {
            project.configurations.consumable(BASELINE_REPORT_ELEMENTS) {
                attributes { baselineReportAttributes(project.objects) }
                outgoing.artifact(report) { builtBy(withoutBaseline) }
            }
        }
    }
}
