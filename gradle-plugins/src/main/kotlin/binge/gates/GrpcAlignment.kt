package binge.gates

/**
 * The `[versions]` table of a Gradle version catalog, as key to version. Only what the alignment needs: a plain string,
 * or a table such as `{ strictly = "1.2" }`, `{ require = "1.2" }` or `{ prefer = "1.2" }`. A line outside `[versions]`
 * is ignored, so a library that happens to share the key's name is not read as a version.
 */
internal fun catalogVersions(lines: List<String>): Map<String, String> {
    val versions = mutableMapOf<String, String>()
    var inVersions = false
    lines.forEach { raw ->
        val line = raw.substringBefore('#').trim()
        if (line.startsWith("[")) {
            inVersions = line.removeSuffix("]").removePrefix("[").trim() == "versions"
            return@forEach
        }
        if (!inVersions || '=' !in line) return@forEach
        val key = line.substringBefore('=').trim().trim('"')
        val value = line.substringAfter('=').trim()
        val version =
            when {
                value.startsWith("\"") -> value.removePrefix("\"").substringBefore('"')
                value.startsWith("{") -> TABLE_VERSION.find(value)?.groupValues?.get(2)
                else -> null
            }
        if (version != null) versions[key] = version
    }
    return versions
}

private val TABLE_VERSION = Regex("""\b(strictly|require|prefer)\s*=\s*"([^"]*)"""")

/** What one side of the comparison was read as. [problem] is set when it could not be read. */
internal class GrpcSide(
    val label: String,
    val key: String,
    val version: String?,
    val problem: String?,
)

internal fun readGrpcSide(
    label: String,
    key: String,
    lines: List<String>?,
    missingHint: String,
): GrpcSide {
    if (lines == null) return GrpcSide(label, key, null, "$label cannot be read. $missingHint")
    val version = catalogVersions(lines)[key]
    val problem = if (version == null) "$label has no [versions] entry named $key. Set the version key if the catalog names it differently." else null
    return GrpcSide(label, key, version, problem)
}

/** The failure messages, empty when the two agree. Either side unreadable is a failure and not a pass. */
internal fun grpcAlignmentProblems(
    consumer: GrpcSide,
    contracts: GrpcSide,
): List<String> {
    val unreadable = listOfNotNull(consumer.problem, contracts.problem)
    if (unreadable.isNotEmpty()) return unreadable
    if (consumer.version == contracts.version) return emptyList()
    return listOf(
        "gRPC versions disagree: ${consumer.label} has ${consumer.key} = ${consumer.version}, " +
            "${contracts.label} has ${contracts.key} = ${contracts.version}. " +
            "The app has to resolve the version the contracts build was written against: update ${consumer.label}, " +
            "or move the contracts submodule to a commit that uses ${consumer.version}.",
    )
}
