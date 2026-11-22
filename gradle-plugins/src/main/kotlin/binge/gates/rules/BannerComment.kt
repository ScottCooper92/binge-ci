package binge.gates.rules

import com.intellij.psi.PsiComment
import dev.detekt.api.Config
import dev.detekt.api.Entity
import dev.detekt.api.Finding
import dev.detekt.api.Rule

/**
 * Flags banner / ruler comments — a comment carrying a run of repeated ruler characters
 * (`──────`, `======`, `------`), with or without a section title. Group related code into a
 * well-named type or file instead.
 */
class BannerComment(
    config: Config = Config.empty,
) : Rule(
        config,
        "Banner/ruler comments are disallowed; name a type or file for the section instead.",
    ) {
    override fun visitComment(comment: PsiComment) {
        super.visitComment(comment)
        if (hasRulerRun(comment.text)) {
            report(
                Finding(
                    entity = Entity.from(comment),
                    message =
                        "This looks like a banner/ruler comment. Remove it and group the code " +
                            "into a well-named type or file.",
                ),
            )
        }
    }

    private fun hasRulerRun(text: String): Boolean {
        var last = ' '
        var run = 0
        for (ch in text) {
            if (ch in RULER_CHARS) {
                run = if (ch == last) run + 1 else 1
                if (run >= MIN_RULER_RUN) return true
            } else {
                run = 0
            }
            last = ch
        }
        return false
    }

    companion object {
        private const val MIN_RULER_RUN = 3

        // Em-dash (—) is deliberately excluded: it is heavily used as prose punctuation here.
        private val RULER_CHARS = "-=_~─═━".toSet()
    }
}
