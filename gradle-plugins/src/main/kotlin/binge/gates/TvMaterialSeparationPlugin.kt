package binge.gates

import org.gradle.api.Plugin
import org.gradle.api.Project
import org.gradle.api.file.ConfigurableFileCollection
import org.gradle.api.file.DirectoryProperty
import org.gradle.api.provider.ListProperty
import org.gradle.api.provider.Property
import org.gradle.api.provider.SetProperty

/** Configuration for `binge.gates.tv-material-separation`. */
abstract class TvMaterialSeparationExtension {
    /** The Kotlin files to scan. Required: the check fails if this finds nothing. */
    abstract val sources: ConfigurableFileCollection

    /** Paths are reported, and matched below, relative to this. Defaults to the settings directory. */
    abstract val rootDirectory: DirectoryProperty

    /** Directories under [rootDirectory] that are TV source throughout, such as a TV module. */
    abstract val tvModulePaths: ListProperty<String>

    /** The package segment that marks TV source anywhere else. Defaults to `tv`. */
    abstract val tvPackage: Property<String>

    /** Package segments, possibly several deep, whose files may import neither library. */
    abstract val neutralPackages: ListProperty<String>

    /** Files under [rootDirectory] allowed to cross: a token adapter, and nothing else. */
    abstract val allowlist: SetProperty<String>

    /** The theme or token types a TV component is projected from, quoted in the failure message. */
    abstract val themeTypeNames: ListProperty<String>
}

/** Registers `checkTvMaterialSeparation`, wired into `check`. */
class TvMaterialSeparationPlugin : Plugin<Project> {
    override fun apply(project: Project) {
        val gate = project.extensions.create("tvMaterialSeparation", TvMaterialSeparationExtension::class.java)
        gate.rootDirectory.convention(project.layout.settingsDirectory)
        gate.tvPackage.convention("tv")

        val check =
            project.tasks.register("checkTvMaterialSeparation", CheckTvMaterialSeparationTask::class.java) {
                group = "verification"
                description = "Checks that Material 3 and tv-material stay on their own sides of the TV seam."
                sourceFiles.from(gate.sources)
                rootDirectory.set(gate.rootDirectory)
                tvModulePaths.set(gate.tvModulePaths)
                tvPackage.set(gate.tvPackage)
                neutralPackages.set(gate.neutralPackages)
                allowlist.set(gate.allowlist)
                themeTypeNames.set(gate.themeTypeNames)
            }
        project.wireIntoCheck(check)
    }
}
