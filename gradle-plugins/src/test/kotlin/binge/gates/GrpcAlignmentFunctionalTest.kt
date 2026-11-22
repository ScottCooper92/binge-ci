package binge.gates

import org.gradle.testkit.runner.GradleRunner
import org.gradle.testkit.runner.internal.PluginUnderTestMetadataReading
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.io.TempDir
import java.io.File

/** Applies `binge.gates.grpc-alignment` by id and runs `check`. */
class GrpcAlignmentFunctionalTest {
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

    private fun build(config: String = "contractsCatalog = layout.settingsDirectory.file(\"contracts/gradle/libs.versions.toml\")") {
        write("settings.gradle.kts", "rootProject.name = \"sample\"\n")
        write("build.gradle.kts", "plugins { id(\"binge.gates.grpc-alignment\") }\ngrpcAlignment { $config }\n")
        write("gradle.properties", "org.gradle.jvmargs=-Xmx1g -XX:MaxMetaspaceSize=1g\n")
    }

    private fun runner() =
        GradleRunner
            .create()
            .withProjectDir(root)
            .withPluginClasspath(PluginUnderTestMetadataReading.readImplementationClasspath())
            .withArguments("check", "--stacktrace")

    @Test
    fun `check passes when the two catalogs agree`() {
        build()
        write("gradle/libs.versions.toml", "[versions]\ngrpc = \"1.80.0\"\n")
        write("contracts/gradle/libs.versions.toml", "[versions]\ngrpc = \"1.80.0\"\n")

        runner().build()
    }

    @Test
    fun `check fails when they differ, naming both files`() {
        build()
        write("gradle/libs.versions.toml", "[versions]\ngrpc = \"1.79.0\"\n")
        write("contracts/gradle/libs.versions.toml", "[versions]\ngrpc = \"1.80.0\"\n")

        val out = runner().buildAndFail().output

        assertTrue(out.contains("gradle/libs.versions.toml has grpc = 1.79.0"), out)
        assertTrue(out.contains("contracts/gradle/libs.versions.toml has grpc = 1.80.0"), out)
    }

    @Test
    fun `check fails, and says to initialise the submodule, when the contracts catalog is not there`() {
        build()
        write("gradle/libs.versions.toml", "[versions]\ngrpc = \"1.80.0\"\n")

        val out = runner().buildAndFail().output

        assertTrue(out.contains("contracts/gradle/libs.versions.toml cannot be read"), out)
        assertTrue(out.contains("git submodule update --init"), out)
    }

    @Test
    fun `check fails when the contracts catalog is not configured`() {
        build(config = "")
        write("gradle/libs.versions.toml", "[versions]\ngrpc = \"1.80.0\"\n")

        val out = runner().buildAndFail().output

        assertTrue(out.contains("Set grpcAlignment.contractsCatalog"), out)
    }

    @Test
    fun `the two catalogs may name the version differently`() {
        build(
            """
            contractsCatalog = layout.settingsDirectory.file("contracts/libs.toml")
            contractsVersionKey = "grpcVersion"
            """.trimIndent(),
        )
        write("gradle/libs.versions.toml", "[versions]\ngrpc = \"1.80.0\"\n")
        write("contracts/libs.toml", "[versions]\ngrpcVersion = \"1.80.0\"\n")

        runner().build()
    }
}
