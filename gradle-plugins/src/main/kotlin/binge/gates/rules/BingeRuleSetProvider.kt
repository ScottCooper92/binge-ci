package binge.gates.rules

import dev.detekt.api.RuleSet
import dev.detekt.api.RuleSetId
import dev.detekt.api.RuleSetProvider

/**
 * Registers the comment rules the apps share. The ruleset id (`binge`) is the namespace the rules are configured under
 * in a detekt config file.
 *
 * Only the lexical comment rules are here: the ones that need no type resolution and no repository-specific allowlist.
 */
class BingeRuleSetProvider : RuleSetProvider {
    override val ruleSetId: RuleSetId = RuleSetId("binge")

    override fun instance(): RuleSet =
        RuleSet(
            ruleSetId,
            listOf(
                ::BannerComment,
                ::ConsecutiveInlineComments,
                ::DeclarationCommentShouldBeKDoc,
                ::KDocLength,
            ),
        )
}
