package binge.gates

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Test

class ScanSeamTest {
    private val rules =
        SeamRules(
            tvModulePaths = listOf("ui-tv"),
            tvPackage = "tv",
            neutralPackages = listOf("catalog/registry"),
        )

    @Test
    fun `classifies by module path, then package segment, with neutral first`() {
        assertEquals(SeamSide.TV, rules.sideOf("ui-tv/src/main/kotlin/a/Button.kt"))
        assertEquals(SeamSide.TV, rules.sideOf("app/src/main/kotlin/a/tv/Home.kt"))
        assertEquals(SeamSide.PHONE, rules.sideOf("app/src/main/kotlin/a/tvshow/Home.kt"))
        assertEquals(SeamSide.NEUTRAL, rules.sideOf("app/src/main/kotlin/catalog/registry/tv/Entry.kt"))
    }

    @Test
    fun `reports imports across the seam and ignores the same names in prose`() {
        val scan =
            scanSeam(
                mapOf(
                    "app/src/main/kotlin/a/tv/Home.kt" to
                        listOf(
                            "/** Never androidx.compose.material3.MaterialTheme here. */",
                            "import androidx.compose.material3.Text",
                            "import androidx.tv.material3.Surface",
                        ),
                    "app/src/main/kotlin/a/Phone.kt" to listOf("import androidx.tv.material3.Card"),
                    "app/src/main/kotlin/catalog/registry/Entry.kt" to listOf("import androidx.compose.material3.Text"),
                ),
                rules,
                allowlist = emptySet(),
            )

        assertEquals(
            listOf(
                "app/src/main/kotlin/a/Phone.kt:1: phone source imports androidx.tv.material3.Card",
                "app/src/main/kotlin/a/tv/Home.kt:2: TV source imports androidx.compose.material3.Text",
                "app/src/main/kotlin/catalog/registry/Entry.kt:1: shared source imports androidx.compose.material3.Text",
            ),
            scan.violations,
        )
    }

    @Test
    fun `an allowlisted adapter passes and is recorded as used`() {
        val adapter = "ui-tv/src/main/kotlin/a/Tokens.kt"
        val scan = scanSeam(mapOf(adapter to listOf("import androidx.compose.material3.ColorScheme")), rules, setOf(adapter))

        assertEquals(emptyList<String>(), scan.violations)
        assertEquals(setOf(adapter), scan.usedAllowlistEntries)
    }
}
