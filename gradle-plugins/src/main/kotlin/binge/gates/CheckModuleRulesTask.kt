package binge.gates

import org.gradle.api.DefaultTask
import org.gradle.api.GradleException
import org.gradle.api.artifacts.component.ModuleComponentIdentifier
import org.gradle.api.artifacts.component.ModuleComponentSelector
import org.gradle.api.artifacts.component.ProjectComponentIdentifier
import org.gradle.api.artifacts.result.ResolvedComponentResult
import org.gradle.api.artifacts.result.ResolvedDependencyResult
import org.gradle.api.artifacts.result.UnresolvedDependencyResult
import org.gradle.api.provider.ListProperty
import org.gradle.api.provider.Property
import org.gradle.api.tasks.Input
import org.gradle.api.tasks.Internal
import org.gradle.api.tasks.TaskAction
import org.gradle.work.DisableCachingByDefault

/**
 * Fails when a module depends on, or sees, what its kind may not.
 *
 * The modules' resolved classpaths are the evidence, so a dependency that arrives through another library counts
 * as seen. It has no outputs, so it runs every time: a classpath is not something a hash of the build file covers.
 */
@DisableCachingByDefault(because = "Verification task over resolved classpaths; its result is not worth caching.")
abstract class CheckModuleRulesTask : DefaultTask() {
    @get:Input
    internal abstract val kinds: ListProperty<ModuleKindRule>

    @get:Input
    abstract val projectPaths: ListProperty<String>

    @get:Input
    abstract val requireEveryProject: Property<Boolean>

    // Resolved lazily, at execution. Not an input: the task has no outputs, so it is never up to date.
    @get:Internal
    abstract val roots: ListProperty<ResolvedComponentResult>

    @TaskAction
    fun check() {
        val unresolved = mutableListOf<String>()
        val graphs = graphsOf(roots.get(), unresolved)
        if (unresolved.isNotEmpty()) {
            // A classpath that did not resolve shows only part of what a module sees, which is how a ban is missed.
            throw GradleException(
                "checkModuleRules could not resolve every classpath it reads, so it cannot say what a module sees:\n" +
                    unresolved.sorted().distinct().joinToString("\n") { "  $it" },
            )
        }
        if (kinds.get().isEmpty()) {
            throw GradleException("checkModuleRules has no kinds. Declare them in moduleRules { kind(\"...\") { ... } }.")
        }
        val result = checkModuleRules(kinds.get(), projectPaths.get(), graphs, requireEveryProject.get())
        if (result.violations.isEmpty()) return
        throw GradleException(
            "Module rules are broken:\n" +
                result.violations.joinToString("\n") { "  $it" } +
                "\nChange the dependency, or change moduleRules if the layering is meant to move.",
        )
    }
}

/**
 * Reads each root's direct project dependencies and everything it reaches, merged per project.
 *
 * A project of this build is a project edge, keyed by its path. A project of an included build is not: its path is
 * relative to its own build, so `:core` there is not `:core` here. It is a library the app consumes, so it is recorded
 * by its coordinates, both the module the dependency asked for (what a dependency substitution replaced) and the
 * project's own, and a `forbid` pattern matches either.
 */
internal fun graphsOf(
    roots: List<ResolvedComponentResult>,
    unresolved: MutableList<String>,
): List<ModuleGraph> {
    val projectDeps = mutableMapOf<String, MutableSet<String>>()
    val coordinates = mutableMapOf<String, MutableMap<String, String>>()
    roots.forEach { root ->
        val id = root.id as? ProjectComponentIdentifier ?: return@forEach
        val path = id.projectPath
        val prefix = id.buildPrefix()
        val deps = projectDeps.getOrPut(path) { mutableSetOf() }
        val seen = coordinates.getOrPut(path) { mutableMapOf() }
        root.dependencies.forEach { edge ->
            when (edge) {
                is UnresolvedDependencyResult -> unresolved += "$path: ${edge.attempted.displayName}"
                is ResolvedDependencyResult -> {
                    val childId = edge.selected.id
                    val local = childId is ProjectComponentIdentifier && childId.buildPrefix() == prefix
                    val via = if (local) (childId as ProjectComponentIdentifier).projectPath else edge.requested.displayName
                    if (local) deps += (childId as ProjectComponentIdentifier).projectPath
                    record(edge, via, seen, prefix)
                    walk(edge.selected, via, seen, unresolved, path, prefix)
                }
            }
        }
    }
    return projectDeps.map { (path, deps) -> ModuleGraph(path, deps, coordinates.getValue(path)) }
}

private fun ProjectComponentIdentifier.buildPrefix(): String = buildPrefix(buildTreePath, projectPath)

/** What a dependency edge shows a module to see: the selected module, or an included build's project by coordinates. */
private fun record(
    edge: ResolvedDependencyResult,
    via: String,
    seen: MutableMap<String, String>,
    ownerPrefix: String,
) {
    val component = edge.selected
    when (val id = component.id) {
        is ModuleComponentIdentifier -> seen.putIfAbsent("${id.group}:${id.module}", via)
        is ProjectComponentIdentifier ->
            if (id.buildPrefix() != ownerPrefix) {
                component.moduleVersion?.let { seen.putIfAbsent("${it.group}:${it.name}", via) }
                (edge.requested as? ModuleComponentSelector)?.let { seen.putIfAbsent("${it.group}:${it.module}", via) }
            }
    }
}

private fun walk(
    start: ResolvedComponentResult,
    via: String,
    seen: MutableMap<String, String>,
    unresolved: MutableList<String>,
    owner: String,
    ownerPrefix: String,
) {
    val visited = mutableSetOf<ResolvedComponentResult>()
    val queue = ArrayDeque(listOf(start))
    while (queue.isNotEmpty()) {
        val component = queue.removeFirst()
        if (!visited.add(component)) continue
        component.dependencies.forEach { edge ->
            when (edge) {
                is UnresolvedDependencyResult -> unresolved += "$owner: ${edge.attempted.displayName}"
                is ResolvedDependencyResult -> {
                    record(edge, via, seen, ownerPrefix)
                    queue.add(edge.selected)
                }
            }
        }
    }
}

/**
 * The build tree path of the build a project belongs to, from the project's own build tree path and project path:
 * empty for the root build of the tree, `:shared` for an included build, `:consumer` for a consumer build that is
 * itself included from a parent. A project belongs to the owner's build when the two match, wherever that build sits
 * in the tree. Comparing the build tree path with the project path alone only works in the root build of the tree.
 */
internal fun buildPrefix(
    buildTreePath: String,
    projectPath: String,
): String =
    if (projectPath == ":") buildTreePath.takeIf { it != ":" } ?: "" else buildTreePath.removeSuffix(projectPath)
