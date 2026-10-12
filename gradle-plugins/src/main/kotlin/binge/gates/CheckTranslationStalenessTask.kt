package binge.gates

import org.gradle.api.DefaultTask
import org.gradle.api.GradleException
import org.gradle.api.file.ConfigurableFileCollection
import org.gradle.api.file.DirectoryProperty
import org.gradle.api.file.RegularFileProperty
import org.gradle.api.provider.Property
import org.gradle.api.tasks.Input
import org.gradle.api.tasks.InputFiles
import org.gradle.api.tasks.Internal
import org.gradle.api.tasks.PathSensitive
import org.gradle.api.tasks.PathSensitivity
import org.gradle.api.tasks.TaskAction
import org.gradle.work.DisableCachingByDefault
import org.w3c.dom.Element
import java.io.File
import java.security.MessageDigest
import javax.xml.parsers.DocumentBuilderFactory

private const val HASH_LENGTH = 12

/**
 * Fails the build when a source string changes and its translations are not re-confirmed.
 *
 * Lint already catches a missing translation, an extra one, a missing plural form and a drifted
 * placeholder. Editing the source string trips none of them: the translation is still present and
 * well-formed, merely wrong now. So the hash of each translated source value is committed, and the
 * build fails when it moves. Re-stamping is the acknowledgement, which is why there is no allowlist.
 */
@DisableCachingByDefault(because = "Source-scanning verification task; its result is not worth caching.")
abstract class CheckTranslationStalenessTask : DefaultTask() {
    @get:InputFiles
    @get:PathSensitive(PathSensitivity.RELATIVE)
    abstract val stringFiles: ConfigurableFileCollection

    // @InputFiles rather than @InputFile: the first stamp runs before the file exists.
    @get:InputFiles
    @get:PathSensitive(PathSensitivity.RELATIVE)
    abstract val hashFile: RegularFileProperty

    @get:Internal
    abstract val repoRoot: DirectoryProperty

    /** The update task sets this; the check leaves it false and reports instead. */
    @get:Input
    abstract val rewrite: Property<Boolean>

    @TaskAction
    fun check() {
        val root = repoRoot.get().asFile
        // Both tasks refuse, not only the check: an update that stamped nothing would write a file
        // the check then agrees with on every later rewording.
        misconfiguration(root, stringFiles.files)?.let { throw GradleException(it) }
        val expected = computeHashes(root, stringFiles.files)
        val file = hashFile.get().asFile

        if (rewrite.getOrElse(false)) {
            file.parentFile?.mkdirs()
            file.writeText(render(expected))
            logger.lifecycle("Wrote ${expected.size} source hashes to ${file.name}.")
            return
        }

        val committed = parseHashes(if (file.exists()) file.readText() else "")
        if (committed == expected) return

        val changed = expected.keys.filter { it in committed && committed[it] != expected[it] }
        val added = expected.keys - committed.keys
        val removed = committed.keys - expected.keys

        throw GradleException(
            buildString {
                append("Translated source strings changed without their translations being re-confirmed.\n\n")
                appendSection("Source text edited - read each translation and fix it if it no longer matches", changed)
                appendSection("Newly translated, not yet stamped", added)
                appendSection("Stamped but no longer translated (string or locale deleted)", removed)
                append("Then run ./gradlew updateTranslationHashes and commit ${file.name} alongside the change.")
            },
        )
    }
}

private fun StringBuilder.appendSection(
    title: String,
    keys: Collection<String>,
) {
    if (keys.isEmpty()) return
    append(title).append(":\n")
    keys.sorted().forEach { append("  ").append(it).append("\n") }
    append("\n")
}

private fun render(hashes: Map<String, String>): String =
    buildString {
        append("# The hash of every source string a locale translates, so an edit to the source cannot\n")
        append("# pass silently while a translation still carries the old wording. Generated -\n")
        append("# run ./gradlew updateTranslationHashes after re-reading the translations it names.\n")
        hashes.toSortedMap().forEach { (key, hash) -> append(key).append("  ").append(hash).append("\n") }
    }

internal fun parseHashes(text: String): Map<String, String> =
    text
        .lineSequence()
        .map { it.substringBefore('#').trim() }
        .filter { it.isNotEmpty() }
        .mapNotNull { line ->
            val parts = line.split(Regex("\\s+"))
            if (parts.size == 2) parts[0] to parts[1] else null
        }.toMap()

/**
 * Why the files cannot be what the gate was meant to read, or null when they can. A gate that reads
 * nothing passes everything, which is how a misconfigured one goes unnoticed: globs that match no
 * strings file, or a [TranslationStalenessExtension.rootDirectory] that gives a module's translations
 * a different key from its source, both produce an empty hash file the check then agrees with.
 *
 * Deliberately not "no hashes": a project whose locales translate none of the source strings yet is
 * configured correctly, and must pass. So this asks about the files, not the result.
 */
internal fun misconfiguration(
    root: File,
    files: Collection<File>,
): String? {
    val sources = mutableSetOf<String>()
    val translations = mutableSetOf<String>()
    files.forEach { file ->
        val relativePath = file.relativeTo(root).invariantSeparatorsPath
        when (resourceKindOf(relativePath)) {
            StringsKind.SOURCE -> sources += moduleOf(relativePath)
            StringsKind.TRANSLATION -> translations += moduleOf(relativePath)
            null -> Unit
        }
    }
    if (sources.isEmpty() && translations.isEmpty()) {
        return "The translation-staleness gate found no strings file under a res/values directory, so it has " +
            "nothing to check. Set translationStaleness.includes, excludes or rootDirectory so they match the " +
            "project's strings.xml files."
    }
    val orphaned = translations - sources
    if (orphaned.isNotEmpty()) {
        return "The translation-staleness gate found translations with no source strings file under the same " +
            "module key, so it cannot hash them: ${orphaned.sorted().joinToString(", ")}. Check that " +
            "translationStaleness.includes reaches the res/values/strings.xml beside each translation, and that " +
            "rootDirectory is where the module paths start."
    }
    return null
}

/** The module a strings file belongs to: its path up to `/src/`, or `.` for a project at the root. */
private fun moduleOf(relativePath: String): String =
    // The leading slash gives a project at the root a delimiter to find; without it substringBefore
    // returns the whole path, source and translation get different keys, and nothing is hashed.
    "/$relativePath".substringBefore("/src/").removePrefix("/").ifEmpty { "." }

/**
 * Hashes the source value of every entry that at least one locale translates, keyed by module so
 * a failure names something a person can open. A module can contribute several `values/strings.xml`
 * (one per source set), so entries are merged, and the files are sorted first so the result depends
 * on the set of files rather than the order the collection yields them.
 */
internal fun computeHashes(
    root: File,
    files: Collection<File>,
): Map<String, String> {
    val sources = mutableMapOf<String, MutableMap<String, String>>()
    val translated = mutableMapOf<String, MutableSet<String>>()

    files.sortedBy { it.relativeTo(root).invariantSeparatorsPath }.forEach { file ->
        val relativePath = file.relativeTo(root).invariantSeparatorsPath
        val module = moduleOf(relativePath)
        when (resourceKindOf(relativePath)) {
            StringsKind.SOURCE -> sources.getOrPut(module) { linkedMapOf() }.putAll(readEntries(file))
            StringsKind.TRANSLATION -> translated.getOrPut(module) { mutableSetOf() } += readEntries(file).keys
            null -> Unit
        }
    }

    return sources
        .flatMap { (module, entries) ->
            val hasTranslation = translated[module].orEmpty()
            entries.filterKeys { it in hasTranslation }.map { (name, value) -> "$module:$name" to sha256(value) }
        }.toMap()
}

internal enum class StringsKind { SOURCE, TRANSLATION }

/**
 * Whether a strings file is the source, a translation, or neither. Only a `values` directory whose
 * qualifiers name a locale is a translation. `values-night`, `values-sw600dp` or `values-v21`
 * override strings for a configuration, not a language, so they are left out: stamping them would
 * hash strings no translator reads, and a module with only such an override is not orphaned.
 */
internal fun resourceKindOf(relativePath: String): StringsKind? {
    val directory = valuesDirectoryOf(relativePath) ?: return null
    if (directory == "values") return StringsKind.SOURCE
    if (!directory.startsWith("values-")) return null
    return if (hasLocaleQualifier(directory.removePrefix("values-"))) StringsKind.TRANSLATION else null
}

/**
 * Android orders qualifiers with the mobile country and network codes first and the locale next,
 * so the locale is the first qualifier after any `mccNNN` or `mncNN`. It is a two- or three-letter
 * language (`es`, `es-rUS`) or the BCP 47 form (`b+sr+Latn`). `car` is the one three-letter
 * qualifier that is not a language: it is a UI mode, and it can only appear first when no locale does.
 */
private fun hasLocaleQualifier(qualifiers: String): Boolean {
    val first = qualifiers.split('-').firstOrNull { !MOBILE_CODE.matches(it) } ?: return false
    return first.startsWith("b+") || (LANGUAGE.matches(first) && first != "car")
}

private val MOBILE_CODE = Regex("(mcc|mnc)[0-9]+")
private val LANGUAGE = Regex("[a-z]{2,3}")

/** The `values`-ish directory a resource file sits in, or null if the path is not under `res/`. */
private fun valuesDirectoryOf(relativePath: String): String? {
    val parts = relativePath.split('/')
    val index = parts.indexOf("res")
    return if (index >= 0 && index + 1 < parts.size) parts[index + 1] else null
}

/**
 * Every `<string>` and `<plurals>` keyed by name, skipping `translatable="false"`. DOM rather than
 * a regex because the value is what is hashed: entity escapes and multi-line text must resolve the
 * same way here as for the reader. A plurals entry hashes its quantities and their text.
 */
private fun readEntries(file: File): Map<String, String> {
    val document =
        DocumentBuilderFactory
            .newInstance()
            .apply { isNamespaceAware = false }
            .newDocumentBuilder()
            .parse(file)
    val entries = linkedMapOf<String, String>()
    val children = document.documentElement?.childNodes ?: return entries
    for (index in 0 until children.length) {
        val element = children.item(index) as? Element ?: continue
        val name = element.getAttribute("name").takeIf { it.isNotEmpty() } ?: continue
        if (element.getAttribute("translatable") == "false") continue
        when (element.tagName) {
            "string" -> entries[name] = element.textContent
            "plurals" -> entries[name] = quantitiesOf(element)
        }
    }
    return entries
}

private fun quantitiesOf(plurals: Element): String {
    val items = plurals.childNodes
    return (0 until items.length)
        .mapNotNull { items.item(it) as? Element }
        .joinToString(" ") { "${it.getAttribute("quantity")}=${it.textContent}" }
}

private fun sha256(value: String): String =
    MessageDigest
        .getInstance("SHA-256")
        .digest(value.toByteArray())
        .joinToString("") { byte -> "%02x".format(byte) }
        .take(HASH_LENGTH)
