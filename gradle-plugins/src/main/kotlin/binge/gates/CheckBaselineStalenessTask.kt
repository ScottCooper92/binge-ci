package binge.gates

import org.gradle.api.DefaultTask
import org.gradle.api.GradleException
import org.gradle.api.file.RegularFileProperty
import org.gradle.api.tasks.InputFile
import org.gradle.api.tasks.PathSensitive
import org.gradle.api.tasks.PathSensitivity
import org.gradle.api.tasks.TaskAction
import org.gradle.work.DisableCachingByDefault

/**
 * Fails when the detekt baseline holds an entry the code no longer produces.
 *
 * An orphaned entry reads as debt still owed, and it silently absorbs the next real finding of that
 * rule in that file. detekt passes on an entry that matches nothing, so nothing else can see one.
 */
@DisableCachingByDefault(because = "Compares two files; its result is not worth caching.")
abstract class CheckBaselineStalenessTask : DefaultTask() {
    @get:InputFile
    @get:PathSensitive(PathSensitivity.RELATIVE)
    abstract val baselineFile: RegularFileProperty

    /** The XML report of a detekt run with no baseline applied. */
    @get:InputFile
    @get:PathSensitive(PathSensitivity.RELATIVE)
    abstract val reportFile: RegularFileProperty

    @TaskAction
    fun check() {
        val baseline = baselineFile.get().asFile
        val stale = staleBaselineEntries(baseline.readText(), reportFile.get().asFile.readText())
        if (stale.isEmpty()) return
        throw GradleException(
            "${baseline.name} holds ${stale.size} entr${if (stale.size == 1) "y" else "ies"} " +
                "the code no longer produces:\n" + stale.joinToString("\n") { "  $it" } +
                "\n\nDelete them. An entry that matches nothing absorbs the next real finding of " +
                "that rule in that file.",
        )
    }
}

/**
 * Each baselined rule-and-file pair the report no longer accounts for, sorted. Entries are compared
 * per rule and file rather than by full signature, because the report carries no signature; a rule
 * with several findings in one file is therefore counted.
 */
internal fun staleBaselineEntries(
    baselineXml: String,
    reportXml: String,
): List<String> {
    val baselined = mutableMapOf<String, Int>()
    Regex("<ID>([^<]+)</ID>").findAll(baselineXml).forEach { match ->
        val id = match.groupValues[1]
        val rule = id.substringBefore(':')
        val file = id.substringAfter(':').substringBefore('$')
        baselined.merge("$rule in $file", 1, Int::plus)
    }
    val reported = mutableMapOf<String, Int>()
    var currentFile = ""
    reportXml.lines().forEach { line ->
        Regex("""<file name="([^"]+)"""").find(line)?.let { currentFile = it.groupValues[1].substringAfterLast('/') }
        Regex("""source="detekt\.([^"]+)"""").find(line)?.let {
            reported.merge("${it.groupValues[1]} in $currentFile", 1, Int::plus)
        }
    }
    return baselined
        .filter { (key, count) -> count > (reported[key] ?: 0) }
        .map { (key, count) -> "$key - baselined $count, reported ${reported[key] ?: 0}" }
        .sorted()
}
