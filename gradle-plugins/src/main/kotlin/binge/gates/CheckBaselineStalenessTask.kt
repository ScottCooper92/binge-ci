package binge.gates

import org.gradle.api.DefaultTask
import org.gradle.api.GradleException
import org.gradle.api.file.ConfigurableFileCollection
import org.gradle.api.file.RegularFileProperty
import org.gradle.api.tasks.InputFile
import org.gradle.api.tasks.InputFiles
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

    /**
     * The XML reports of detekt runs with no baseline applied: one per project that shares the
     * baseline. A report that does not exist is read as no findings, for a run that was skipped.
     */
    @get:InputFiles
    @get:PathSensitive(PathSensitivity.RELATIVE)
    abstract val reportFiles: ConfigurableFileCollection

    @TaskAction
    fun check() {
        val baseline = baselineFile.get().asFile
        val reports = reportFiles.files.filter { it.exists() }.map { it.readText() }
        val stale = staleBaselineEntries(baseline.readText(), reports)
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
 * Each baselined rule-and-file pair the reports no longer account for, sorted. Entries are compared
 * per rule and file rather than by full signature, because a report carries no signature; a rule
 * with several findings in one file is therefore counted. Findings are summed across [reportXmls],
 * because a baseline shared by several projects names a file by its name alone.
 */
internal fun staleBaselineEntries(
    baselineXml: String,
    reportXmls: List<String>,
): List<String> {
    val baselined = mutableMapOf<String, Int>()
    Regex("<ID>([^<]+)</ID>").findAll(baselineXml).forEach { match ->
        // detekt 2.x writes `Rule:File.kt:signature`. A file name holds no colon, and a signature can.
        val (rule, file) = match.groupValues[1].split(':', limit = 3)
        baselined.merge("$rule in $file", 1, Int::plus)
    }
    val reported = mutableMapOf<String, Int>()
    var currentFile = ""
    reportXmls.flatMap { it.lines() }.forEach { line ->
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
