package binge.gates

import java.io.Serializable

/** One kind of module and what it may do. Built by the extension, read by the task: a plain value. */
internal data class ModuleKindRule(
    val name: String,
    /** Gradle project paths. `*` is one path segment, `**` is any number of them. */
    val projects: List<String>,
    /** Kinds a module of this kind may depend on, besides its own. */
    val mayDependOn: Set<String>,
    /** `group:artifact` patterns a module of this kind may not see. `*` is any run of characters. */
    val forbid: List<String>,
) : Serializable

/** What one module's resolved classpaths showed: its direct project dependencies, and every external module it sees. */
internal data class ModuleGraph(
    val path: String,
    val projectDependencies: Set<String>,
    /** `group:artifact` to the direct dependency it arrived through. */
    val coordinates: Map<String, String>,
)

internal class ModuleRulesResult(
    val violations: List<String>,
)

/** A glob over [separator]-delimited names: `*` stays inside one segment, `**` crosses them. */
internal fun globToRegex(
    glob: String,
    separator: Char,
): Regex {
    val sb = StringBuilder()
    var i = 0
    while (i < glob.length) {
        val c = glob[i]
        if (c == '*') {
            if (i + 1 < glob.length && glob[i + 1] == '*') {
                sb.append(".*")
                i += 2
                continue
            }
            sb.append("[^").append(Regex.escape(separator.toString())).append("]*")
        } else {
            sb.append(Regex.escape(c.toString()))
        }
        i++
    }
    return Regex(sb.toString())
}

/** A coordinate pattern: `*` matches any run of characters, including `:` and `.`. */
internal fun coordinateRegex(pattern: String): Regex = Regex(pattern.split("*").joinToString(".*") { Regex.escape(it) })

/**
 * Holds every module to its kind. A rule that cannot be applied is a failure and not a pass, since a gate
 * that checks nothing passes everything: a module in no kind, a path pattern that matches no module, a kind
 * named in `mayDependOn` that does not exist, and a module that matches two kinds.
 */
internal fun checkModuleRules(
    kinds: List<ModuleKindRule>,
    projectPaths: Collection<String>,
    graphs: Collection<ModuleGraph>,
    requireEveryProject: Boolean,
): ModuleRulesResult {
    val violations = mutableListOf<String>()
    val kindNames = kinds.map { it.name }.toSet()

    val matchers = kinds.associate { kind -> kind.name to kind.projects.map { it to globToRegex(it, ':') } }
    val kindOf = mutableMapOf<String, String>()
    val usedPatterns = mutableSetOf<Pair<String, String>>()
    projectPaths.sorted().forEach { path ->
        val hits =
            kinds.filter { kind ->
                matchers.getValue(kind.name).any { (pattern, regex) ->
                    regex.matches(path).also { if (it) usedPatterns += kind.name to pattern }
                }
            }
        when {
            hits.size > 1 -> violations += "$path matches more than one kind (${hits.joinToString { it.name }}); a module has one kind."
            hits.size == 1 -> kindOf[path] = hits.single().name
            requireEveryProject -> violations += "$path is in no kind. Add it to one, or list it in moduleRules.ignoreProjects."
        }
    }
    kinds.forEach { kind ->
        kind.projects.filter { (kind.name to it) !in usedPatterns }.forEach {
            violations += "Kind ${kind.name} lists $it, which matches no project. Delete it, or fix the path."
        }
        kind.mayDependOn.filter { it !in kindNames }.forEach {
            violations += "Kind ${kind.name} may depend on $it, which is not a kind. Known kinds: ${kindNames.sorted().joinToString()}."
        }
    }

    val byName = kinds.associateBy { it.name }
    graphs.sortedBy { it.path }.forEach { graph ->
        val kindName = kindOf[graph.path] ?: return@forEach
        val kind = byName.getValue(kindName)
        graph.projectDependencies.sorted().forEach { target ->
            val targetKind = kindOf[target]
            when {
                targetKind == null ->
                    violations += "${graph.path} ($kindName) depends on $target, which is in no kind, so $kindName may not depend on it."
                targetKind != kindName && targetKind !in kind.mayDependOn ->
                    violations +=
                        "${graph.path} ($kindName) depends on $target ($targetKind). " +
                        "A $kindName module may depend on: ${(setOf(kindName) + kind.mayDependOn).sorted().joinToString()}."
            }
        }
        val bans = kind.forbid.map { it to coordinateRegex(it) }
        graph.coordinates.toSortedMap().forEach { (coordinate, via) ->
            bans.firstOrNull { (_, regex) -> regex.matches(coordinate) }?.let { (pattern, _) ->
                violations += "${graph.path} ($kindName) sees $coordinate, through $via. A $kindName module may not see $pattern."
            }
        }
    }
    return ModuleRulesResult(violations)
}
