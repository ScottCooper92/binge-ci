package binge.gates

import dev.detekt.gradle.Detekt
import org.gradle.api.GradleException
import org.gradle.api.Project
import org.gradle.api.provider.Property
import java.util.concurrent.atomic.AtomicInteger

/**
 * detekt prints `There were N compiler errors found during analysis. This affects accuracy of reporting.` and still
 * passes. A type-resolved rule has nothing to check on an expression whose type depends on a failed resolution, so the
 * `!!` and `runCatching` bans go quiet for it with a green build. This reads that line and holds the count to
 * `allowedCompilerErrors`, so a new unresolved symbol fails the build instead of widening the blind spot.
 */
internal object CompilerErrorRatchet {
    // detekt words it as `There was 1 compiler error` or `There were N compiler errors`; read the number, not the phrase.
    private val LINE = Regex("""There (?:was|were) (\d+) compiler errors? found during analysis""")

    private const val NO_LIMIT = -1

    fun wire(
        project: Project,
        allowed: Property<Int>,
    ) {
        val projectPath = project.path
        project.tasks.withType(Detekt::class.java).configureEach {
            val taskName = name
            val count = AtomicInteger(0)
            // An input, so a changed limit reruns the task instead of leaving it up to date and unchecked.
            inputs.property("allowedCompilerErrors", allowed.orElse(NO_LIMIT))
            doFirst {
                count.set(0)
                logging.addStandardOutputListener { text ->
                    LINE.find(text)?.let { count.set(it.groupValues[1].toInt()) }
                }
            }
            doLast {
                val found = count.get()
                if (found == 0) return@doLast
                val limit = allowed.orNull
                val where = "$projectPath:$taskName"
                when {
                    limit == null ->
                        logger.warn(
                            "binge.gates.detekt: $where reported $found compiler error(s), so type-resolved rules (the !! ban, " +
                                "ForbiddenMethodCall) are blind to the code that did not resolve. Set " +
                                "detektGate { allowedCompilerErrors = $found } to fail on any new one, and detekt { debug = true } " +
                                "to read them.",
                        )
                    found > limit ->
                        throw GradleException(
                            "binge.gates.detekt: $where reported $found compiler error(s) but detektGate.allowedCompilerErrors is $limit. " +
                                "A new unresolved symbol widens the blind spot of the type-resolved rules. Fix it, or read the " +
                                "errors with detekt { debug = true } first.",
                        )
                    found < limit ->
                        logger.lifecycle(
                            "binge.gates.detekt: $where reported $found compiler error(s), fewer than the $limit allowed. " +
                                "Lower detektGate.allowedCompilerErrors to $found so they cannot come back.",
                        )
                }
            }
        }
    }
}
