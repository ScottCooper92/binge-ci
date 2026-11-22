package binge.gates.rules

import com.intellij.psi.PsiComment
import com.intellij.psi.PsiElement
import com.intellij.psi.PsiWhiteSpace
import dev.detekt.api.Config
import dev.detekt.api.Entity
import dev.detekt.api.Finding
import dev.detekt.api.Rule
import org.jetbrains.kotlin.lexer.KtTokens
import org.jetbrains.kotlin.psi.KtClassBody
import org.jetbrains.kotlin.psi.KtClassOrObject
import org.jetbrains.kotlin.psi.KtDeclaration
import org.jetbrains.kotlin.psi.KtEnumEntry
import org.jetbrains.kotlin.psi.KtFile
import org.jetbrains.kotlin.psi.KtNamedFunction
import org.jetbrains.kotlin.psi.KtProperty

/**
 * Flags a `//` comment sitting directly above a top-level or class-member declaration that has no
 * KDoc: declaration docs belong in `/** … */`. A `//` aside inside a
 * function body — including above a local `fun` — is fine and is not flagged; only top-level and
 * member declarations are checked. Enum entries are exempt (their inline `//` notes are idiomatic).
 */
class DeclarationCommentShouldBeKDoc(
    config: Config = Config.empty,
) : Rule(
        config,
        "A comment documenting a declaration should be KDoc (/** */), not //.",
    ) {
    override fun visitClassOrObject(classOrObject: KtClassOrObject) {
        super.visitClassOrObject(classOrObject)
        if (classOrObject !is KtEnumEntry) check(classOrObject)
    }

    override fun visitNamedFunction(function: KtNamedFunction) {
        super.visitNamedFunction(function)
        check(function)
    }

    override fun visitProperty(property: KtProperty) {
        super.visitProperty(property)
        check(property)
    }

    private fun check(declaration: KtDeclaration) {
        val parent = declaration.parent
        if (parent !is KtFile && parent !is KtClassBody) return
        if (declaration.docComment != null) return
        val comment = precedingLineComment(declaration) ?: return
        report(
            Finding(
                entity = Entity.from(comment),
                message = "This // comment documents '${declaration.name}'. Make it a KDoc /** */ block.",
            ),
        )
    }

    private fun precedingLineComment(declaration: KtDeclaration): PsiComment? {
        val text = declaration.containingKtFile.text
        // A leading line comment is bound as the declaration's first child (as KDoc is), or, when
        // unbound, sits as a preceding sibling. Check the child form first, then the sibling form.
        leadingChildComment(declaration, text)?.let { return it }
        var sibling = declaration.prevSibling
        if (sibling is PsiWhiteSpace) {
            // A blank line means the comment is a detached aside, not this declaration's doc.
            if (sibling.text.count { it == '\n' } > 1) return null
            sibling = sibling.prevSibling
        }
        return (sibling as? PsiComment)?.takeIf { isStandaloneEol(it, text) }
    }

    private fun leadingChildComment(
        declaration: KtDeclaration,
        text: String,
    ): PsiComment? {
        var child: PsiElement? = declaration.firstChild
        while (child != null) {
            when {
                child is PsiWhiteSpace -> child = child.nextSibling
                child is PsiComment -> return child.takeIf { isStandaloneEol(it, text) }
                else -> return null
            }
        }
        return null
    }

    private fun isStandaloneEol(
        comment: PsiComment,
        text: String,
    ): Boolean {
        if (comment.tokenType != KtTokens.EOL_COMMENT) return false
        // Ignore a trailing comment on a line that also holds code.
        val start = comment.textRange.startOffset
        val lineStart = text.lastIndexOf('\n', start - 1) + 1
        return text.substring(lineStart, start).isBlank()
    }
}
