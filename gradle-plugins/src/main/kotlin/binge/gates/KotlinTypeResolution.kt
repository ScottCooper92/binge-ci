package binge.gates

import dev.detekt.gradle.Detekt
import dev.detekt.gradle.DetektCreateBaselineTask
import org.gradle.api.Project
import org.jetbrains.kotlin.gradle.dsl.KotlinAndroidProjectExtension
import org.jetbrains.kotlin.gradle.dsl.KotlinJvmProjectExtension
import org.jetbrains.kotlin.gradle.plugin.KotlinCompilation
import org.jetbrains.kotlin.gradle.plugin.mpp.KotlinJvmAndroidCompilation
import org.jetbrains.kotlin.gradle.tasks.KotlinCompileTool

/** Every reference to a Kotlin Gradle plugin type lives here, so the class only loads when the plugin can. */
internal object KotlinTypeResolution {
    fun wire(
        project: Project,
        requestedCompilation: String?,
    ) {
        val production =
            project.extensions
                .findByType(KotlinJvmProjectExtension::class.java)
                ?.target
                ?.let { it to (requestedCompilation ?: KotlinCompilation.MAIN_COMPILATION_NAME) }
                ?: project.extensions
                    .findByType(KotlinAndroidProjectExtension::class.java)
                    ?.target
                    ?.let { it to (requestedCompilation ?: "debug") }
        if (production == null) {
            project.logger.warn("binge.gates.detekt: ${project.path} has no Kotlin JVM or Android target, so detekt runs without type resolution.")
            return
        }
        val (target, compilationName) = production

        target.compilations.configureEach {
            if (name != compilationName) return@configureEach
            // `libraries` is the compile task's classpath, already resolved for the variant. Resolving
            // the compilation's dependency files directly trips AGP's variant ambiguity.
            val classpathFiles = compileTaskProvider.map { (it as KotlinCompileTool).libraries }
            val outputClasses = output.classesDirs
            // AGP compiles BuildConfig with javac, into a directory the Kotlin compilation's own output
            // leaves out. Without it detekt cannot resolve a read of BuildConfig, counts a compiler
            // error, and stops applying the rules that need types to that code.
            val javaClasses =
                (this as? KotlinJvmAndroidCompilation)?.compileJavaTaskProvider?.flatMap { it.destinationDirectory }
            project.tasks.withType(Detekt::class.java).configureEach {
                classpath.from(classpathFiles, outputClasses)
                if (javaClasses != null) classpath.from(javaClasses)
            }
            project.tasks.withType(DetektCreateBaselineTask::class.java).configureEach {
                classpath.from(classpathFiles, outputClasses)
                if (javaClasses != null) classpath.from(javaClasses)
            }
        }
    }
}
