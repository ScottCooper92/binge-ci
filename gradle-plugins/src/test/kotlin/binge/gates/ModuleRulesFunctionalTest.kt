package binge.gates

import org.gradle.testkit.runner.GradleRunner
import org.gradle.testkit.runner.internal.PluginUnderTestMetadataReading
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.io.TempDir
import java.io.File

/** Applies `binge.gates.module-rules` by id to a multi-project build and runs `check`. */
class ModuleRulesFunctionalTest {
    @TempDir
    lateinit var root: File

    private fun write(
        path: String,
        text: String,
    ) {
        File(root, path).apply {
            parentFile.mkdirs()
            writeText(text)
        }
    }

    /** A local Maven repository with one empty library per coordinate, so no network is needed. */
    private fun library(
        group: String,
        name: String,
        vararg requires: String,
    ) {
        val dir = "repo/${group.replace('.', '/')}/$name/1.0"
        val deps =
            requires.joinToString("") {
                val (g, n) = it.split(":")
                "<dependency><groupId>$g</groupId><artifactId>$n</artifactId><version>1.0</version></dependency>"
            }
        write("$dir/$name-1.0.pom", "<project><modelVersion>4.0.0</modelVersion><groupId>$group</groupId><artifactId>$name</artifactId><version>1.0</version><dependencies>$deps</dependencies></project>")
        File(root, "$dir/$name-1.0.jar").writeBytes(ByteArray(0))
    }

    private fun build(
        rules: String,
        modules: Map<String, String>,
    ) {
        write("settings.gradle.kts", "rootProject.name = \"sample\"\ninclude(${modules.keys.joinToString { "\"$it\"" }})\n")
        write(
            "build.gradle.kts",
            """
            plugins { id("binge.gates.module-rules") }
            allprojects { repositories { maven { url = uri("${File(root, "repo").toURI()}") } } }
            subprojects { apply(plugin = "java-library") }
            $rules
            """.trimIndent(),
        )
        modules.forEach { (path, deps) -> write("${path.replace(':', '/')}/build.gradle.kts", deps) }
        write("gradle.properties", "org.gradle.jvmargs=-Xmx1g -XX:MaxMetaspaceSize=1g\n")
    }

    private val layers =
        """
        moduleRules {
            kind("contracts") { projects(":contracts") }
            kind("data") {
                projects(":data")
                mayDependOn("contracts")
                forbid("com.acme.ui:*", "com.acme.di:injector")
            }
            kind("app") { projects(":app"); mayDependOn("data", "contracts") }
        }
        """.trimIndent()

    private fun runner(vararg args: String): GradleRunner =
        GradleRunner
            .create()
            .withProjectDir(root)
            .withPluginClasspath(PluginUnderTestMetadataReading.readImplementationClasspath())
            .withArguments(*args, "--stacktrace")

    @Test
    fun `a layered build passes check`() {
        library("com.acme.ui", "widgets")
        build(
            layers,
            mapOf(
                "contracts" to "",
                "data" to """dependencies { api(project(":contracts")) }""",
                "app" to """dependencies { implementation(project(":data")); implementation("com.acme.ui:widgets:1.0") }""",
            ),
        )

        runner("check").build()
    }

    @Test
    fun `a banned library and a forbidden project reached only through test configurations pass check`() {
        library("com.acme.ui", "widgets")
        build(
            layers,
            mapOf(
                "contracts" to "",
                "data" to """dependencies { testImplementation("com.acme.ui:widgets:1.0"); testImplementation(project(":app")) }""",
                "app" to "",
            ),
        )

        runner("check").build()
    }

    @Test
    fun `a forbidden project edge fails check and names the module and the kinds it may use`() {
        build(
            layers,
            mapOf(
                "contracts" to "",
                "data" to """dependencies { implementation(project(":app")) }""",
                "app" to "",
            ),
        )

        val out = runner("check").buildAndFail().output

        assertTrue(out.contains(":data (data) depends on :app (app)"), out)
        assertTrue(out.contains("A data module may depend on: contracts, data."), out)
    }

    @Test
    fun `a banned library fails check when it arrives through another library, and says which`() {
        library("com.acme.ui", "widgets")
        library("com.acme.net", "client", "com.acme.ui:widgets")
        build(
            layers,
            mapOf(
                "contracts" to "",
                "data" to """dependencies { api(project(":contracts")); implementation("com.acme.net:client:1.0") }""",
                "app" to "",
            ),
        )

        val out = runner("check").buildAndFail().output

        assertTrue(out.contains(":data (data) sees com.acme.ui:widgets, through com.acme.net:client:1.0"), out)
    }

    @Test
    fun `a JVM module's test classpath is not held to its kind`() {
        library("com.acme.ui", "widgets")
        build(
            layers,
            mapOf(
                "contracts" to "",
                "data" to
                    """
                    dependencies {
                        api(project(":contracts"))
                        testImplementation(project(":app"))
                        testImplementation("com.acme.ui:widgets:1.0")
                    }
                    """.trimIndent(),
                "app" to "",
            ),
        )

        runner("check").build()
    }

    @Test
    fun `settings work in a root script that applies a plugin with resolvable configurations`() {
        write("settings.gradle.kts", "rootProject.name = \"sample\"\ninclude(\"data\", \"tools\")\n")
        write(
            "build.gradle.kts",
            """
            plugins {
                id("binge.gates.module-rules")
                `java-library`
            }
            moduleRules {
                ignoreProjects.add(":tools")
                kind("data") { projects(":data") }
            }
            subprojects { apply(plugin = "java-library") }
            """.trimIndent(),
        )
        write("data/build.gradle.kts", "")
        write("tools/build.gradle.kts", "dependencies { implementation(project(\":data\")) }")
        write("gradle.properties", "org.gradle.jvmargs=-Xmx1g -XX:MaxMetaspaceSize=1g\n")

        runner("check").build()
    }

    @Test
    fun `adding to a list keeps the built-in entries, so the root and the test classpaths stay out`() {
        library("com.acme.ui", "widgets")
        build(
            """
            moduleRules {
                ignoreProjects.add(":tools")
                excludeConfigurations.add("noSuchClasspath*")
                kind("data") { projects(":data"); forbid("com.acme.ui:*") }
            }
            """.trimIndent(),
            mapOf(
                "data" to """dependencies { testImplementation("com.acme.ui:widgets:1.0") }""",
                "tools" to "",
            ),
        )

        runner("check").build()
    }

    @Test
    fun `a project in no kind fails check`() {
        build(
            layers,
            mapOf("contracts" to "", "data" to "", "app" to "", "tools" to ""),
        )

        val out = runner("check").buildAndFail().output

        assertTrue(out.contains(":tools is in no kind"), out)
    }

    @Test
    fun `it runs with the configuration cache on, and again from the cache`() {
        library("com.acme.ui", "widgets")
        build(
            layers,
            mapOf(
                "contracts" to "",
                "data" to """dependencies { api(project(":contracts")) }""",
                "app" to """dependencies { implementation(project(":data")) }""",
            ),
        )

        runner("check", "--configuration-cache").build()
        val again = runner("check", "--configuration-cache").build().output

        assertTrue(again.contains("Reusing configuration cache"), again)
    }
}
