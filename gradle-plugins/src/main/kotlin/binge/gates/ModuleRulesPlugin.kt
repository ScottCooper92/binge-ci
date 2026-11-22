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

        /** Project paths that are not checked, such as the root project. Defaults to `:`. */
        abstract val ignoreProjects: ListProperty<String>

        /**
         * The resolvable configurations read, by name, with `*` as a wildcard. Defaults to the compile and runtime
         * classpaths of every variant, which is what a module can see.
         */
        abstract val configurations: ListProperty<String>

        /** Configurations left out of [configurations]. Defaults to the test ones, including `testFixtures`. */
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
        rules.ignoreProjects.convention(listOf(":"))
        rules.configurations.convention(listOf("compileClasspath", "runtimeClasspath", "*CompileClasspath", "*RuntimeClasspath"))
        rules.excludeConfigurations.convention(listOf("test*", "*Test*"))
        // Configurations are filtered as they are created, so a value set after the first read would be ignored.
        // Finalizing on read turns that order into an error.
        rules.ignoreProjects.finalizeValueOnRead()
        rules.configurations.finalizeValueOnRead()
        rules.excludeConfigurations.finalizeValueOnRead()

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
                        val ignored = rules.ignoreProjects.get().map { globToRegex(it, ':') }
                        project.allprojects.map { it.path }.filter { path -> ignored.none { it.matches(path) } }
                    },
                )
            }

        // Each resolvable classpath hands its root component to the task as a lazy provider, so nothing is resolved
        // until the task runs, and the configuration cache can hold it. The root build script is evaluated before
        // the other projects, so the extension is set by the time their configurations appear.
        project.allprojects {
            val owner = this
            configurations.configureEach {
                if (!isCanBeResolved) return@configureEach
                val ignored = rules.ignoreProjects.get().map { globToRegex(it, ':') }
                if (ignored.any { it.matches(owner.path) }) return@configureEach
                val include = rules.configurations.get().map { globToRegex(it, ':') }
                val exclude = rules.excludeConfigurations.get().map { globToRegex(it, ':') }
                if (include.none { it.matches(name) } || exclude.any { it.matches(name) }) return@configureEach
                check.configure { roots.add(incoming.resolutionResult.rootComponent) }
            }
        }
        project.wireIntoCheck(check)
    }
}
