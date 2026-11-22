package binge.gates

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

class GrpcAlignmentTest {
    private fun side(
        label: String,
        text: String?,
        key: String = "grpc",
    ) = readGrpcSide(label, key, text?.lines(), "hint")

    @Test
    fun `reads a plain version, a table form, and ignores everything outside the versions table`() {
        val versions =
            catalogVersions(
                """
                # grpc = "0.0.1"
                [versions]
                grpc = "1.80.0" # the runtime
                protobuf = { strictly = "4.31.1" }
                okio = { prefer = "3.9.0" }
                kotlin = { require = "2.4.0" }
                [libraries]
                grpc = { module = "io.grpc:grpc-okhttp", version.ref = "grpc" }
                [plugins]
                grpc = { id = "x", version = "9.9.9" }
                """.trimIndent().lines(),
            )
        assertEquals(mapOf("grpc" to "1.80.0", "protobuf" to "4.31.1", "okio" to "3.9.0", "kotlin" to "2.4.0"), versions)
    }

    @Test
    fun `agreeing catalogs have no problem`() {
        val a = side("app/libs.versions.toml", "[versions]\ngrpc = \"1.80.0\"")
        val b = side("contracts/libs.versions.toml", "[versions]\ngrpc = \"1.80.0\"")
        assertEquals(emptyList<String>(), grpcAlignmentProblems(a, b))
    }

    @Test
    fun `differing catalogs name both files and both versions`() {
        val a = side("app/libs.versions.toml", "[versions]\ngrpc = \"1.79.0\"")
        val b = side("contracts/libs.versions.toml", "[versions]\ngrpc = \"1.80.0\"")
        val problem = grpcAlignmentProblems(a, b).single()
        assertTrue(problem.contains("app/libs.versions.toml has grpc = 1.79.0"), problem)
        assertTrue(problem.contains("contracts/libs.versions.toml has grpc = 1.80.0"), problem)
    }

    @Test
    fun `a catalog that cannot be read, or has no such key, is a failure and not a pass`() {
        val good = side("a", "[versions]\ngrpc = \"1\"")
        assertTrue(grpcAlignmentProblems(good, side("b", null)).single().contains("b cannot be read. hint"))
        assertTrue(grpcAlignmentProblems(good, side("b", "[versions]\nother = \"1\"")).single().contains("b has no [versions] entry named grpc"))
        assertEquals(2, grpcAlignmentProblems(side("a", null), side("b", null)).size)
    }

    @Test
    fun `each side may name the version differently`() {
        val a = side("a", "[versions]\ngrpc = \"1.80.0\"")
        val b = side("b", "[versions]\ngrpcVersion = \"1.80.0\"", key = "grpcVersion")
        assertEquals(emptyList<String>(), grpcAlignmentProblems(a, b))
    }
}
