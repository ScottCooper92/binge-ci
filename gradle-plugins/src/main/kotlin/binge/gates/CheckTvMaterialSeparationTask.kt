package binge.gates

import org.gradle.api.DefaultTask
import org.gradle.api.GradleException
import org.gradle.api.file.ConfigurableFileCollection
import org.gradle.api.file.DirectoryProperty
import org.gradle.api.provider.ListProperty
import org.gradle.api.provider.Property
import org.gradle.api.provider.SetProperty
import org.gradle.api.tasks.Input
import org.gradle.api.tasks.InputFiles
import org.gradle.api.tasks.Internal
import org.gradle.api.tasks.PathSensitive
import org.gradle.api.tasks.PathSensitivity
import org.gradle.api.tasks.TaskAction
import org.gradle.work.DisableCachingByDefault

/**
 * Fails when the two Material libraries are mixed.
 *
 * `androidx.tv.material3` and `androidx.compose.material3` each ship their own `MaterialTheme`, with
 * separate colour, shape and type trees. The two symbols share a simple name, so the wrong import
 * compiles cleanly and renders subtly wrong. Neither ktlint nor detekt can see the difference.
 */
@DisableCachingByDefault(because = "Source-scanning verification task; its result is not worth caching.")
abstract class CheckTvMaterialSeparationTask : DefaultTask() {
    @get:InputFiles
    @get:PathSensitive(PathSensitivity.RELATIVE)
    abstract val sourceFiles: ConfigurableFileCollection

    @get:Internal
    abstract val rootDirectory: DirectoryProperty

    @get:Input
    abstract val tvModulePaths: ListProperty<String>

    @get:Input
    abstract val tvPackage: Property<String>

    @get:Input
    abstract val neutralPackages: ListProperty<String>

    @get:Input
    abstract val allowlist: SetProperty<String>

    @get:Input
    abstract val themeTypeNames: ListProperty<String>

    @TaskAction
    fun check() {
        val root = rootDirectory.get().asFile
        val files =
            sourceFiles.files
                .filter { it.isFile }
                .associate { it.relativeTo(root).invariantSeparatorsPath to it.readLines() }
        // A gate that scans nothing passes everything, which is how a misconfigured one goes unnoticed.
        if (files.isEmpty()) {
            throw GradleException("checkTvMaterialSeparation found no source files. Set tvMaterialSeparation.sources.")
        }

        val allowed = allowlist.get()
        val scan = scanSeam(files, SeamRules(tvModulePaths.get(), tvPackage.get(), neutralPackages.get()), allowed)

        val stale = allowed - scan.usedAllowlistEntries
        if (stale.isNotEmpty()) {
            logger.lifecycle(
                "Allowlist entries with no cross-seam import left; delete them so the list shrinks:\n" +
                    stale.sorted().joinToString("\n") { "  $it" },
            )
        }
        if (scan.violations.isEmpty()) return

        throw GradleException(
            buildString {
                append("Material 3 and tv-material must not be mixed. TV source may only use androidx.tv.material3; ")
                append("phone source may only use androidx.compose.material3, and shared source neither. ")
                append("A component cannot be composed across the seam: give the TV surface its own component")
                val themes = themeTypeNames.get()
                if (themes.isNotEmpty()) append(", projected from the same ").append(themes.joinToString(", "))
                append(". A token adapter that translates between the two type systems is the only ")
                append("sanctioned crossing; add it to the allowlist with a reason.\n\nViolations:\n")
                append(scan.violations.joinToString("\n") { "  $it" })
            },
        )
    }
}
