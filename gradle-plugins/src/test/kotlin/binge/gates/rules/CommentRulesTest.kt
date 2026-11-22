package binge.gates.rules

import dev.detekt.test.lint
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Test

class BannerCommentTest {
    @Test
    fun `flags an ascii ruler banner`() {
        val findings = BannerComment().lint("// ------ Section ------\nval x = 1\n")
        assertEquals(1, findings.size)
    }

    @Test
    fun `flags a box-drawing ruler`() {
        val findings = BannerComment().lint("// ──────────────\nval x = 1\n")
        assertEquals(1, findings.size)
    }

    @Test
    fun `ignores an ordinary why-comment with an em-dash`() {
        val findings = BannerComment().lint("// keep this — it explains the guard\nval x = 1\n")
        assertEquals(0, findings.size)
    }
}

class ConsecutiveInlineCommentsTest {
    @Test
    fun `flags a run of four standalone comment lines`() {
        val code =
            """
            // one
            // two
            // three
            // four
            val x = 1
            """.trimIndent() + "\n"
        assertEquals(1, ConsecutiveInlineComments().lint(code).size)
    }

    @Test
    fun `allows a run of three`() {
        val code =
            """
            // one
            // two
            // three
            val x = 1
            """.trimIndent() + "\n"
        assertEquals(0, ConsecutiveInlineComments().lint(code).size)
    }

    @Test
    fun `ignores trailing comments that share a line with code`() {
        val code =
            """
            val a = 1 // trailing one
            val b = 2 // trailing two
            val c = 3 // trailing three
            val d = 4 // trailing four
            val e = 5 // trailing five
            """.trimIndent() + "\n"
        assertEquals(0, ConsecutiveInlineComments().lint(code).size)
    }
}

class DeclarationCommentShouldBeKDocTest {
    @Test
    fun `flags a slash-comment above a top-level declaration`() {
        val code = "// documents the constant\nconst val X = 1\n"
        assertEquals(1, DeclarationCommentShouldBeKDoc().lint(code).size)
    }

    @Test
    fun `flags a slash-comment above a member function`() {
        val code =
            """
            class Foo {
                // documents the member
                fun bar() = Unit
            }
            """.trimIndent() + "\n"
        assertEquals(1, DeclarationCommentShouldBeKDoc().lint(code).size)
    }

    @Test
    fun `accepts a KDoc above a declaration`() {
        val code = "/** documents the constant */\nconst val X = 1\n"
        assertEquals(0, DeclarationCommentShouldBeKDoc().lint(code).size)
    }

    @Test
    fun `ignores an aside inside a function body`() {
        val code =
            """
            fun outer() {
                // an in-body aside
                val local = 1
                // above a local fun
                fun inner() = Unit
            }
            """.trimIndent() + "\n"
        assertEquals(0, DeclarationCommentShouldBeKDoc().lint(code).size)
    }

    @Test
    fun `ignores a detached comment separated by a blank line`() {
        val code = "// a detached aside\n\nconst val X = 1\n"
        assertEquals(0, DeclarationCommentShouldBeKDoc().lint(code).size)
    }
}

class KDocLengthTest {
    private fun kdoc(vararg lines: String) = "/**\n" + lines.joinToString("\n") { " * $it" } + "\n */\n"

    @Test
    fun `flags a class KDoc of seven prose lines`() {
        val code = kdoc("one", "two", "three", "four", "five", "six", "seven") + "class Foo\n"
        assertEquals(1, KDocLength().lint(code).size)
    }

    @Test
    fun `allows a class KDoc of six prose lines`() {
        val code = kdoc("one", "two", "three", "four", "five", "six") + "class Foo\n"
        assertEquals(0, KDocLength().lint(code).size)
    }

    @Test
    fun `flags a function KDoc and a property KDoc over the cap`() {
        val code =
            kdoc("one", "two", "three", "four", "five", "six", "seven") + "fun foo() = Unit\n" +
                kdoc("one", "two", "three", "four", "five", "six", "seven") + "val bar = 1\n"
        assertEquals(2, KDocLength().lint(code).size)
    }

    @Test
    fun `does not count block tags or their continuation lines`() {
        val code =
            kdoc(
                "one",
                "two",
                "three",
                "four",
                "five",
                "six",
                "@param a the first parameter, described at some length",
                "    and continued on an indented line",
                "@param b the second",
                "@return nothing of note",
            ) + "fun foo(a: Int, b: Int) = Unit\n"
        assertEquals(0, KDocLength().lint(code).size)
    }

    @Test
    fun `does not count blank separator lines`() {
        val code = kdoc("one", "two", "", "three", "four", "", "five", "six") + "class Foo\n"
        assertEquals(0, KDocLength().lint(code).size)
    }

    @Test
    fun `ignores a single-line KDoc and a declaration without one`() {
        val code = "/** documents the constant */\nconst val X = 1\nval y = 2\n"
        assertEquals(0, KDocLength().lint(code).size)
    }
}
