package binge.gates

import dev.detekt.gradle.Detekt
import org.gradle.api.Plugin
import org.gradle.api.Project
import org.gradle.api.file.RegularFile

/**
 * Registers `checkBaselineStaleness`, wired into `check`, and the baseline-free detekt run it reads.
 *
 * Applies `binge.gates.detekt` and reads its baseline, config and source, so the two runs cannot
 * disagree about which rules are on. With no baseline set, or none on disk, both tasks skip.
 */
class BaselineStalenessPlugin : Plugin<Project> {
    override fun apply(project: Project) {
        project.pluginManager.apply(DetektGatePlugin::class.java)
        val gate = project.extensions.getByType(DetektGateExtension::class.java)
        val report = project.layout.buildDirectory.file("reports/detekt/no-baseline.xml")
        val hasBaseline = gate.baselineFile.map { it.asFile.exists() }.orElse(false)

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
            project.tasks.register("checkBaselineStaleness", CheckBaselineStalenessTask::class.java) {
                group = "verification"
                description = "Fails when the detekt baseline holds an entry the code no longer produces."
                dependsOn(withoutBaseline)
                baselineFile.set(gate.baselineFile)
                reportFile.set(report)
                onlyIf("a detekt baseline exists") { hasBaseline.get() }
            }
        project.wireIntoCheck(check)
    }
}
