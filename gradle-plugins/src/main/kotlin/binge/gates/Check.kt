package binge.gates

import org.gradle.api.Project
import org.gradle.api.Task
import org.gradle.api.tasks.TaskProvider
import org.gradle.language.base.plugins.LifecycleBasePlugin

/**
 * Makes [task] part of `check`. The lifecycle plugin is applied first because a gate on a project
 * with no `check` task would be registered, never run, and look like it was passing.
 */
internal fun Project.wireIntoCheck(task: TaskProvider<out Task>) {
    pluginManager.apply(LifecycleBasePlugin::class.java)
    tasks.named(LifecycleBasePlugin.CHECK_TASK_NAME) { dependsOn(task) }
}
