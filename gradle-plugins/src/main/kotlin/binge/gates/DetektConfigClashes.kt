package binge.gates

import org.gradle.api.DefaultTask
import org.gradle.api.GradleException
import org.gradle.api.file.ConfigurableFileCollection
import org.gradle.api.tasks.InputFiles
import org.gradle.api.tasks.PathSensitive
import org.gradle.api.tasks.PathSensitivity
import org.gradle.api.tasks.TaskAction
import org.gradle.work.DisableCachingByDefault

/**
 * The lists a detekt config sets, as `ruleSet>rule>key`: a key three levels down whose value is a list, written inline
 * (`[a, b]`) or as `-` items under it. Read as text because the gate carries no YAML parser; the shape of detekt's config
 * is fixed, and nesting is read from indentation. A list item's own keys (`value:`, `reason:`) sit deeper than the key and
 * are never at the third level.
 */
internal fun listKeys(config: String): Set<String> {
    val lines = config.lines().filter { it.isNotBlank() && !it.trimStart().startsWith("#") }
    val stack = mutableListOf<Pair<Int, String>>()
    val found = linkedSetOf<String>()
    for ((index, line) in lines.withIndex()) {
        val text = line.trimStart()
        if (text.startsWith("- ") || text == "-") continue
        val indent = line.length - text.length
        val key = text.substringBefore(':', missingDelimiterValue = "").trim().trim('\'', '"')
        if (key.isEmpty()) continue
        while (stack.isNotEmpty() && stack.last().first >= indent) stack.removeLast()
        stack += indent to key
        if (stack.size != 3) continue
        val inline = text.substringAfter(':').trim()
        val isList =
            inline.startsWith("[") ||
                (inline.isEmpty() && lines.getOrNull(index + 1)?.trimStart()?.let { it.startsWith("- ") || it == "-" } == true)
        if (isList) found += stack.joinToString(">") { it.second }
    }
    return found
}

/** Each list that more than one of [configs] sets, with the names of the files, in the order they are read. */
internal fun clashingLists(configs: List<Pair<String, String>>): Map<String, List<String>> {
    val setBy = linkedMapOf<String, MutableList<String>>()
    for ((name, text) in configs) listKeys(text).forEach { setBy.getOrPut(it) { mutableListOf() } += name }
    return setBy.filterValues { it.size > 1 }
}

/**
 * Fails when two config files read by one detekt run set the same list. detekt reads a later file over an earlier one key by
 * key and replaces a list rather than merging it, so the earlier file's entries are dropped and nothing says so: a ban
 * a consumer wrote in its own `detekt.yml` would go quiet the day a shared fragment that sets the same list is added.
 */
@DisableCachingByDefault(because = "It only reads the config files and fails; there is nothing to cache.")
abstract class CheckDetektConfigClashesTask : DefaultTask() {
    @get:InputFiles
    @get:PathSensitive(PathSensitivity.NAME_ONLY)
    abstract val configs: ConfigurableFileCollection

    init {
        // Reads files that are not declared outputs of anything; running it is cheap and the answer must be fresh.
        outputs.upToDateWhen { false }
    }

    @TaskAction
    fun check() {
        val read = configs.files.filter { it.isFile }.map { it.name to it.readText() }
        val clashes = clashingLists(read)
        if (clashes.isEmpty()) return
        val detail = clashes.entries.joinToString("\n") { (key, files) -> "  - `${key.replace('>', '.')}` in ${files.joinToString(" and ")}" }
        throw GradleException(
            "binge.gates.detekt: more than one config file sets the same list, and detekt replaces a list rather than merging it, " +
                "so the entries of the earlier file are dropped without a warning:\n$detail\n" +
                "Put the entries of both into one file, or leave the fragment's list out of the consumer's own detekt.yml.",
        )
    }
}
