package binge.gates

import org.gradle.api.Plugin
import org.gradle.api.Project
import org.gradle.api.file.ConfigurableFileCollection
import org.gradle.api.file.DirectoryProperty
import org.gradle.api.file.RegularFileProperty
import org.gradle.api.provider.ListProperty

/** Configuration for `binge.gates.translation-staleness`. */
abstract class TranslationStalenessExtension {
    /** Paths and module keys are relative to this. Defaults to the settings directory. */
    abstract val rootDirectory: DirectoryProperty

    /** The committed hashes. Defaults to `translation-hashes.txt` in [rootDirectory]. */
    abstract val hashFile: RegularFileProperty

    /** Globs under [rootDirectory] for the string files to read. Defaults to every strings file in a `values` directory. */
    abstract val includes: ListProperty<String>

    /** Globs to leave out, such as an included build that checks its own strings. Defaults to build output. */
    abstract val excludes: ListProperty<String>

    /** Further string files, read as well as the ones the globs find. */
    abstract val stringFiles: ConfigurableFileCollection
}

/**
 * Registers `checkTranslationStaleness`, wired into `check`, and `updateTranslationHashes`.
 *
 * Two tasks over one implementation, the way the screenshot plugin pairs validate with update.
 * Splitting them is what makes re-stamping a deliberate act rather than something a check does
 * quietly on your behalf.
 */
class TranslationStalenessPlugin : Plugin<Project> {
    override fun apply(project: Project) {
        val gate = project.extensions.create("translationStaleness", TranslationStalenessExtension::class.java)
        gate.rootDirectory.convention(project.layout.settingsDirectory)
        gate.hashFile.convention(gate.rootDirectory.file("translation-hashes.txt"))
        gate.includes.convention(listOf("**/src/*/res/values/strings.xml", "**/src/*/res/values-*/strings.xml"))
        gate.excludes.convention(listOf("**/build/**"))

        val found =
            project.provider {
                project.fileTree(gate.rootDirectory) {
                    include(gate.includes.get())
                    exclude(gate.excludes.get())
                }
            }

        fun CheckTranslationStalenessTask.wire(rewrites: Boolean) {
            group = "verification"
            stringFiles.from(found, gate.stringFiles)
            hashFile.set(gate.hashFile)
            repoRoot.set(gate.rootDirectory)
            rewrite.set(rewrites)
        }

        val check =
            project.tasks.register("checkTranslationStaleness", CheckTranslationStalenessTask::class.java) {
                description = "Checks that no translated source string changed without its translations being re-confirmed."
                wire(rewrites = false)
            }
        project.tasks.register("updateTranslationHashes", CheckTranslationStalenessTask::class.java) {
            description = "Re-stamps the translation hashes after the named translations have been re-read."
            wire(rewrites = true)
        }
        project.wireIntoCheck(check)
    }
}
