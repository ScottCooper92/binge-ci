package binge.gates

import org.gradle.api.DefaultTask
import org.gradle.api.file.RegularFileProperty
import org.gradle.api.tasks.CacheableTask
import org.gradle.api.tasks.OutputFile
import org.gradle.api.tasks.TaskAction

/**
 * Writes the base detekt config the gate ships inside its own jar to a file detekt can read. A config file is a file on
 * disk, and a consumer holds this plugin as a jar, so it is unpacked into the build directory.
 */
@CacheableTask
abstract class WriteDetektBaseConfigTask : DefaultTask() {
    @get:OutputFile
    abstract val baseFile: RegularFileProperty

    init {
        baseFile.convention(project.layout.buildDirectory.file("binge-gates/detekt-base.yml"))
    }

    @TaskAction
    fun write() {
        val text =
            checkNotNull(javaClass.getResourceAsStream("/binge/gates/detekt-base.yml")) { "detekt-base.yml is missing from the plugin" }
                .use { it.reader().readText() }
        baseFile.get().asFile.apply {
            parentFile.mkdirs()
            writeText(text)
        }
    }
}
