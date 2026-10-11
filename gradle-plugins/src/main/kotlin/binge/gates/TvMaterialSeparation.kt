package binge.gates

internal const val MATERIAL3_PACKAGE = "androidx.compose.material3"
internal const val TV_PACKAGE = "androidx.tv"

/** Which side of the seam a file sits on, and so what it may not import. */
internal enum class SeamSide(
    val label: String,
    val forbidden: List<String>,
) {
    TV("TV source", listOf(MATERIAL3_PACKAGE)),
    PHONE("phone source", listOf(TV_PACKAGE)),
    NEUTRAL("shared source", listOf(MATERIAL3_PACKAGE, TV_PACKAGE)),
}

/**
 * How a path relative to the root is classified. [tvModulePaths] are directories that are TV source
 * whole; [tvPackage] is a path segment that marks TV source anywhere; [neutralPackages] are path
 * segments, possibly several deep, that may import neither library. Neutral wins, then TV.
 */
internal class SeamRules(
    tvModulePaths: Collection<String>,
    tvPackage: String,
    neutralPackages: Collection<String>,
) {
    private val tvPrefixes = tvModulePaths.map { it.trim('/') + "/" }.filter { it != "/" }
    private val tvSegment = tvPackage.trim('/').takeIf { it.isNotEmpty() }?.let { "/$it/" }
    private val neutralSegments = neutralPackages.map { "/" + it.trim('/') + "/" }.filter { it != "//" }

    fun sideOf(relativePath: String): SeamSide {
        val path = "/$relativePath"
        return when {
            neutralSegments.any { it in path } -> SeamSide.NEUTRAL
            tvPrefixes.any { relativePath.startsWith(it) } -> SeamSide.TV
            tvSegment != null && tvSegment in path -> SeamSide.TV
            else -> SeamSide.PHONE
        }
    }
}

internal class SeamScan(
    val violations: List<String>,
    val usedAllowlistEntries: Set<String>,
)

/**
 * Scans import lines only. The package names may appear in a KDoc sentence explaining this very
 * rule, as they do throughout a TV design system, and that is not a crossing.
 */
internal fun scanSeam(
    files: Map<String, List<String>>,
    rules: SeamRules,
    allowlist: Set<String>,
): SeamScan {
    val violations = mutableListOf<String>()
    val used = mutableSetOf<String>()
    files.toSortedMap().forEach { (relativePath, lines) ->
        val side = rules.sideOf(relativePath)
        lines.forEachIndexed { index, line ->
            val trimmed = line.trimStart()
            if (!trimmed.startsWith("import ")) return@forEachIndexed
            val imported = trimmed.removePrefix("import ").trim()
            if (side.forbidden.none { imported.startsWith("$it.") }) return@forEachIndexed
            if (relativePath in allowlist) {
                used += relativePath
            } else {
                violations += "$relativePath:${index + 1}: ${side.label} imports $imported"
            }
        }
    }
    return SeamScan(violations, used)
}
