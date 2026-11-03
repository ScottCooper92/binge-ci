package binge.gates

import org.gradle.api.DefaultTask
import org.gradle.api.GradleException
import org.gradle.api.Project
import org.gradle.api.file.RegularFileProperty
import org.gradle.api.provider.ListProperty
import org.gradle.api.tasks.TaskProvider
import org.gradle.api.tasks.CacheableTask
import org.gradle.api.tasks.Input
import org.gradle.api.tasks.InputFile
import org.gradle.api.tasks.OutputFile
import org.gradle.api.tasks.PathSensitive
import org.gradle.api.tasks.PathSensitivity
import org.gradle.api.tasks.TaskAction

/** detekt's own rule sets, which [DetektGateExtension.suppressedPaths] always covers. */
internal val BUILT_IN_RULE_SETS =
    listOf("comments", "complexity", "coroutines", "empty-blocks", "exceptions", "naming", "performance", "potential-bugs", "style")

/** The generated config layer: `excludes: [globs]` on every rule set in [ruleSets]. */
internal fun suppressionsYaml(
    paths: List<String>,
    ruleSets: List<String>,
): String {
    val globs = paths.joinToString(", ") { "'$it'" }
    return ruleSets.joinToString(separator = "") { "$it:\n  excludes: [$globs]\n" }
}

/**
 * The rule sets in [consumerConfig] that carry their own `excludes`: a key directly under a top-level rule set, as opposed
 * to one under a rule inside it. Read as text because the config is detekt's YAML and the gate carries no parser; the shape
 * is fixed, and the indent a file uses is whatever its first line under each rule set uses.
 */
internal fun ruleSetsWithOwnExcludes(consumerConfig: String): List<String> {
    var ruleSet: String? = null
    var childIndent: Int? = null
    val found = mutableListOf<String>()
    for (line in consumerConfig.lines()) {
        if (line.isBlank() || line.trimStart().startsWith("#")) continue
        val indent = line.length - line.trimStart().length
        if (indent == 0) {
            ruleSet = line.substringBefore(':').trim().takeIf { line.contains(':') }
            childIndent = null
            continue
        }
        if (childIndent == null) childIndent = indent
        if (ruleSet != null && indent == childIndent && line.trimStart().startsWith("excludes:")) found += ruleSet
    }
    return found
}

/**
 * Writes the rule sets' `excludes` that silence findings in the suppressed paths while the files stay analysed. detekt reads
 * a later config file over an earlier one, and the layer is the later, so a rule set of the consumer's own that already
 * carries `excludes` would have them replaced: the files it excluded from that set would start reporting. It fails here
 * instead and names the set.
 */
@CacheableTask
abstract class GenerateDetektSuppressionsTask : DefaultTask() {
    @get:Input abstract val paths: ListProperty<String>

    @get:Input abstract val extraRuleSets: ListProperty<String>

    @get:InputFile
    @get:PathSensitive(PathSensitivity.NONE)
    abstract val consumerConfig: RegularFileProperty

    @get:OutputFile abstract val output: RegularFileProperty

    @TaskAction
    fun generate() {
        val ruleSets = (BUILT_IN_RULE_SETS + extraRuleSets.get()).distinct()
        val config = consumerConfig.asFile.get()
        val clashing = ruleSetsWithOwnExcludes(config.readText()).filter { it in ruleSets }
        if (clashing.isNotEmpty()) {
            throw GradleException(
                "binge.gates.detekt: ${config.name} sets `excludes` on the rule set(s) ${clashing.joinToString()} and " +
                    "detektGate.suppressedPaths is set too. detekt lets the later config file win and the generated layer is " +
                    "later, so it would replace those `excludes`, and the files they leave out would start reporting. Put them on " +
                    "the individual rules instead (a rule's own `excludes` is not replaced), or add the globs to " +
                    "detektGate.suppressedPaths, which silences every rule set for those paths.",
            )
        }
        output.asFile.get().apply {
            parentFile.mkdirs()
            writeText(suppressionsYaml(paths.get(), ruleSets))
        }
    }
}

internal object DetektSuppressions {
    /** The task that writes the generated config. It runs, and its file is added to a detekt task, only while a path is suppressed. */
    fun register(
        project: Project,
        gate: DetektGateExtension,
    ): TaskProvider<GenerateDetektSuppressionsTask> =
        project.tasks.register("generateDetektSuppressions", GenerateDetektSuppressionsTask::class.java) {
            paths.set(gate.suppressedPaths)
            extraRuleSets.set(gate.suppressedRuleSets)
            consumerConfig.set(gate.configFile)
            output.set(project.layout.buildDirectory.file("binge-detekt/suppressions.yml"))
            onlyIf { paths.get().isNotEmpty() }
        }
}
