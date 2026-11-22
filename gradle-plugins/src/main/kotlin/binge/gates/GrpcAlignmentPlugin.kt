package binge.gates

import org.gradle.api.DefaultTask
import org.gradle.api.GradleException
import org.gradle.api.Plugin
import org.gradle.api.Project
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

/** Configuration for `binge.gates.grpc-alignment`. */
abstract class GrpcAlignmentExtension {
    /** Paths are reported relative to this. Defaults to the settings directory. */
    abstract val rootDirectory: DirectoryProperty

    /** The app's own version catalog. Defaults to `gradle/libs.versions.toml` under [rootDirectory]. */
    abstract val catalog: RegularFileProperty

    /** The contracts build's version catalog, in the submodule. Required: the check fails if it is not set. */
    abstract val contractsCatalog: RegularFileProperty

    /** The `[versions]` key holding gRPC's version in [catalog]. Defaults to `grpc`. */
    abstract val versionKey: Property<String>

    /** The key in [contractsCatalog]. Defaults to [versionKey]. */
    abstract val contractsVersionKey: Property<String>
}

/**
 * Fails when the app's gRPC version is not the version the contracts build resolves. A comment saying the two "must
 * agree" is not a check, and the disagreement only shows when the generated stubs meet a runtime that is not theirs.
 */
@DisableCachingByDefault(because = "Reads two small files; its result is not worth caching.")
abstract class CheckGrpcAlignmentTask : DefaultTask() {
    @get:Internal
    abstract val rootDirectory: DirectoryProperty

    // @InputFiles tolerates a file that is not there, so the task can say so itself instead of Gradle refusing to start.
    @get:InputFiles
    @get:PathSensitive(PathSensitivity.RELATIVE)
    abstract val catalogFiles: ConfigurableFileCollection

    @get:Internal
    abstract val catalog: RegularFileProperty

    @get:Internal
    abstract val contractsCatalog: RegularFileProperty

    @get:Input
    abstract val versionKey: Property<String>

    @get:Input
    abstract val contractsVersionKey: Property<String>

    @TaskAction
    fun check() {
        if (!contractsCatalog.isPresent) {
            throw GradleException("checkGrpcAlignment has no contracts catalog to compare with. Set grpcAlignment.contractsCatalog.")
        }
        val root = rootDirectory.get().asFile
        val consumerFile = catalog.get().asFile
        val contractsFile = contractsCatalog.get().asFile
        val consumer =
            readGrpcSide(
                consumerFile.relativeTo(root).invariantSeparatorsPath,
                versionKey.get(),
                consumerFile.takeIf { it.isFile }?.readLines(),
                "Set grpcAlignment.catalog.",
            )
        val contracts =
            readGrpcSide(
                contractsFile.relativeTo(root).invariantSeparatorsPath,
                contractsVersionKey.get(),
                contractsFile.takeIf { it.isFile }?.readLines(),
                "If the contracts submodule is not checked out, run `git submodule update --init`.",
            )
        val problems = grpcAlignmentProblems(consumer, contracts)
        if (problems.isNotEmpty()) throw GradleException(problems.joinToString("\n"))
        logger.lifecycle("gRPC is ${consumer.version} in both catalogs.")
    }
}

/** Registers `checkGrpcAlignment`, wired into `check`. */
class GrpcAlignmentPlugin : Plugin<Project> {
    override fun apply(project: Project) {
        val gate = project.extensions.create("grpcAlignment", GrpcAlignmentExtension::class.java)
        gate.rootDirectory.convention(project.layout.settingsDirectory)
        gate.catalog.convention(gate.rootDirectory.file("gradle/libs.versions.toml"))
        gate.versionKey.convention("grpc")
        gate.contractsVersionKey.convention(gate.versionKey)

        val check =
            project.tasks.register("checkGrpcAlignment", CheckGrpcAlignmentTask::class.java) {
                group = "verification"
                description = "Checks that the app's gRPC version is the one the contracts build resolves."
                rootDirectory.set(gate.rootDirectory)
                catalog.set(gate.catalog)
                contractsCatalog.set(gate.contractsCatalog)
                // A provider with no value breaks a file collection, and an unset contractsCatalog is the task's to report.
                catalogFiles.from(project.provider { listOfNotNull(gate.catalog.orNull?.asFile, gate.contractsCatalog.orNull?.asFile) })
                versionKey.set(gate.versionKey)
                contractsVersionKey.set(gate.contractsVersionKey)
            }
        project.wireIntoCheck(check)
    }
}
