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

    /** The thresholds of the comment rules, read only when `commentRules` is on. */
    @get:OutputFile
    abstract val commentRulesFile: RegularFileProperty

    init {
        baseFile.convention(project.layout.buildDirectory.file("binge-gates/detekt-base.yml"))
        commentRulesFile.convention(project.layout.buildDirectory.file("binge-gates/detekt-comment-rules.yml"))
    }

    @TaskAction
    fun write() {
        unpack("detekt-base.yml", baseFile.get().asFile)
        unpack("detekt-comment-rules.yml", commentRulesFile.get().asFile)
    }

    private fun unpack(
        resource: String,
        target: java.io.File,
    ) {
        val text =
            checkNotNull(javaClass.getResourceAsStream("/binge/gates/$resource")) { "$resource is missing from the plugin" }
                .use { it.reader().readText() }
        target.parentFile.mkdirs()
        target.writeText(text)
    }
}
