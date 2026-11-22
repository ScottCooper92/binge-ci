package binge.gates

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

class ModuleRulesTest {
    private val kinds =
        listOf(
            ModuleKindRule("contracts", listOf(":contracts"), emptySet(), emptyList()),
            ModuleKindRule("data", listOf(":data:*"), setOf("contracts"), listOf("androidx.compose.*", "com.google.dagger:*")),
            ModuleKindRule("client", listOf(":client"), setOf("data", "contracts"), emptyList()),
            ModuleKindRule("app", listOf(":app"), setOf("client", "data", "contracts"), emptyList()),
        )
    private val paths = listOf(":contracts", ":data:movies", ":data:shows", ":client", ":app")

    private fun graph(
        path: String,
        deps: Set<String> = emptySet(),
        coords: Map<String, String> = emptyMap(),
    ) = ModuleGraph(path, deps, coords)

    private fun run(
        graphs: List<ModuleGraph>,
        kinds: List<ModuleKindRule> = this.kinds,
        paths: List<String> = this.paths,
        every: Boolean = true,
    ) = checkModuleRules(kinds, paths, graphs, every).violations

    @Test
    fun `a layered build passes`() {
        val violations =
            run(
                listOf(
                    graph(":data:movies", setOf(":contracts", ":data:shows")),
                    graph(":client", setOf(":data:movies")),
                    graph(":app", setOf(":client", ":contracts"), mapOf("androidx.compose.ui:ui" to ":client")),
                ),
            )
        assertEquals(emptyList<String>(), violations)
    }

    @Test
    fun `a module may depend on its own kind without saying so`() {
        assertEquals(emptyList<String>(), run(listOf(graph(":data:movies", setOf(":data:shows")))))
    }

    @Test
    fun `a dependency on a kind that is not allowed is named with the kinds that are`() {
        val violations = run(listOf(graph(":client", setOf(":app"))))
        assertEquals(1, violations.size)
        assertTrue(violations.single().contains(":client (client) depends on :app (app)"), violations.single())
        assertTrue(violations.single().contains("client, contracts, data"), violations.single())
    }

    @Test
    fun `a forbidden coordinate fails, with the dependency it came through`() {
        val violations = run(listOf(graph(":data:movies", coords = mapOf("androidx.compose.ui:ui" to "com.acme:widgets", "com.squareup.okio:okio" to "x"))))
        assertEquals(1, violations.size)
        assertTrue(violations.single().contains("sees androidx.compose.ui:ui, through com.acme:widgets"), violations.single())
        assertTrue(violations.single().contains("may not see androidx.compose.*"), violations.single())
    }

    @Test
    fun `a coordinate pattern with no star matches only that artifact`() {
        val one = listOf(ModuleKindRule("data", listOf(":d"), emptySet(), listOf("io.grpc:grpc-okhttp")))
        assertEquals(1, run(listOf(graph(":d", coords = mapOf("io.grpc:grpc-okhttp" to "x"))), one, listOf(":d")).size)
        assertEquals(0, run(listOf(graph(":d", coords = mapOf("io.grpc:grpc-okhttp-extra" to "x"))), one, listOf(":d")).size)
    }

    @Test
    fun `a project in no kind fails, unless asked not to`() {
        val extra = paths + ":tools"
        assertTrue(run(emptyList(), paths = extra).single().contains(":tools is in no kind"))
        assertEquals(emptyList<String>(), run(emptyList(), paths = extra, every = false))
    }

    @Test
    fun `a dependency on a project in no kind fails even when unlisted projects are allowed`() {
        val violations = run(listOf(graph(":app", setOf(":tools"))), paths = paths + ":tools", every = false)
        assertTrue(violations.single().contains(":tools, which is in no kind"), violations.single())
    }

    @Test
    fun `a path pattern that matches no project fails`() {
        val violations = run(emptyList(), paths = listOf(":contracts", ":data:movies", ":client", ":app").filter { it != ":client" })
        assertTrue(violations.any { it.contains("Kind client lists :client, which matches no project") }, violations.toString())
    }

    @Test
    fun `a kind named in mayDependOn that does not exist fails`() {
        val bad = listOf(ModuleKindRule("data", listOf(":d"), setOf("contract"), emptyList()))
        assertTrue(run(emptyList(), bad, listOf(":d")).single().contains("may depend on contract, which is not a kind"))
    }

    @Test
    fun `a project in two kinds fails`() {
        val two =
            listOf(
                ModuleKindRule("a", listOf(":x"), emptySet(), emptyList()),
                ModuleKindRule("b", listOf(":x"), emptySet(), emptyList()),
            )
        assertTrue(run(emptyList(), two, listOf(":x")).single().contains(":x matches more than one kind (a, b)"))
    }

    @Test
    fun `a single star stays inside one path segment and a double star crosses them`() {
        assertTrue(globToRegex(":data:*", ':').matches(":data:movies"))
        assertTrue(!globToRegex(":data:*", ':').matches(":data:movies:impl"))
        assertTrue(globToRegex(":data:**", ':').matches(":data:movies:impl"))
        assertTrue(!globToRegex(":data:*", ':').matches(":dataX:movies"))
    }
}
