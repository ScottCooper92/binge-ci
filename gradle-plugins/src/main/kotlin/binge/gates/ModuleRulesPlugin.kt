package binge.gates

import org.gradle.api.Action
import org.gradle.api.Named
import org.gradle.api.NamedDomainObjectContainer
import org.gradle.api.Plugin
import org.gradle.api.Project
import org.gradle.api.provider.ListProperty
import org.gradle.api.provider.Property
import org.gradle.api.provider.SetProperty
import javax.inject.Inject

/** What one kind of module may do. Declared in `moduleRules { kind("data") { ... } }`. */
abstract class ModuleKindSpec
    @Inject
    constructor(
        private val kindName: String,
    ) : Named {
        override fun getName(): String = kindName

        /** Gradle project paths of this kind. `*` is one path segment, `**` any number of them. */
        abstract val projects: ListProperty<String>

        /** Kinds this kind may depend on, besides its own. */
        abstract val mayDependOn: SetProperty<String>

        /** `group:artifact` patterns a module of this kind may not see, directly or through another dependency. */
        abstract val forbid: ListProperty<String>

        fun projects(vararg paths: String) = projects.addAll(*paths)

        fun mayDependOn(vararg kinds: String) = mayDependOn.addAll(*kinds)

        fun forbid(vararg patterns: String) = forbid.addAll(*patterns)
    }

/** Configuration for `binge.gates.module-rules`. Apply it to the root project, and configure it there. */
abstract class ModuleRulesExtension
    @Inject
    constructor(
        objects: org.gradle.api.model.ObjectFactory,
    ) {
        /** The kinds of module, and what each may depend on and see. */
        val kinds: NamedDomainObjectContainer<ModuleKindSpec> = objects.domainObjectContainer(ModuleKindSpec::class.java)

        fun kind(
            name: String,
            action: Action<ModuleKindSpec>,
        ) {
            kinds.maybeCreate(name).also { action.execute(it) }
        }

        /** Fail on a project that is in no kind. On by default, so a new module cannot slip past unchecked. */
        abstract val requireEveryProject: Property<Boolean>

        /** Project paths that are not checked, added to the root project `:`, which never is. `*` is one path segment. */
        abstract val ignoreProjects: ListProperty<String>

        /**
         * Resolvable configurations to read, by name with `*` as a wildcard, added to the compile and runtime classpaths
         * of every variant, which is what a module can see.
         */
        abstract val configurations: ListProperty<String>

        /**
         * Configurations to leave out, added to the test ones, which always are: a JVM module's `test*`, test fixtures
         * included, and an Android module's `*UnitTest*` and `*AndroidTest*`.
         */
        abstract val excludeConfigurations: ListProperty<String>
    }

/** Registers `checkModuleRules` on the root project, wired into `check`. */
class ModuleRulesPlugin : Plugin<Project> {
    override fun apply(project: Project) {
        require(project == project.rootProject) {
            "binge.gates.module-rules is applied to the root project, which reads every other project's classpaths."
        }
        val rules = project.extensions.create("moduleRules", ModuleRulesExtension::class.java)
        rules.requireEveryProject.convention(true)

        val check =
            project.tasks.register("checkModuleRules", CheckModuleRulesTask::class.java) {
                group = "verification"
                description = "Checks that every module depends on, and sees, only what its kind allows."
                requireEveryProject.set(rules.requireEveryProject)
                kinds.set(
                    project.provider {
                        rules.kinds.map { ModuleKindRule(it.name, it.projects.get(), it.mayDependOn.get(), it.forbid.get()) }
                    },
                )
                projectPaths.set(
                    project.provider {
                        val ignored = (BUILT_IN_IGNORED + rules.ignoreProjects.get()).map { globToRegex(it, ':') }
                        project.allprojects.map { it.path }.filter { path -> ignored.none { it.matches(path) } }
                    },
                )
            }

        // Each wanted classpath hands its root component to the task as a lazy provider, so nothing is resolved until
        // the task runs, and the configuration cache can hold it. Which classpaths are wanted is decided once every
        // project is evaluated, so the order of the root script, and of the plugins it applies, does not matter, and
        // a setting made anywhere in it is seen.
        project.gradle.projectsEvaluated {
            val ignored = (BUILT_IN_IGNORED + rules.ignoreProjects.get()).map { globToRegex(it, ':') }
            val include = (BUILT_IN_CLASSPATHS + rules.configurations.get()).map { globToRegex(it, ':') }
            val exclude = (BUILT_IN_EXCLUDED + rules.excludeConfigurations.get()).map { globToRegex(it, ':') }
            project.allprojects.filter { owner -> ignored.none { it.matches(owner.path) } }.forEach { owner ->
                owner.configurations
                    .filter { it.isCanBeResolved }
                    .filter { cfg -> include.any { it.matches(cfg.name) } && exclude.none { it.matches(cfg.name) } }
                    .forEach { cfg -> check.configure { roots.add(cfg.incoming.resolutionResult.rootComponent) } }
            }
        }
        project.wireIntoCheck(check)
    }
}

private val BUILT_IN_IGNORED = listOf(":")
private val BUILT_IN_CLASSPATHS = listOf("compileClasspath", "runtimeClasspath", "*CompileClasspath", "*RuntimeClasspath")
private val BUILT_IN_EXCLUDED = listOf("test*", "*Test*")
