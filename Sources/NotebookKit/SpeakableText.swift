import Foundation

/// An answer as something worth listening to.
///
/// An answer is written to be read, and read aloud it is mostly punctuation.
/// "as described in (vcf-9-1.pdf p2518 (2/6))" is a link on screen and eight
/// seconds of a voice spelling out a filename, a page number and a fraction;
/// markdown is worse, because a synthesiser reads "asterisk asterisk" as
/// faithfully as it reads the words between them.
///
/// **Citations are removed only where the answer is known to name one.** The
/// same conservative match `AnswerLinks` uses to make them clickable decides
/// what is dropped here, so a sentence that happens to contain something shaped
/// like a filename is read as written rather than quietly shortened. The page
/// still carries every citation; what is lost is only the noise of hearing them.
public enum SpeakableText {

    public static func from(answer: String, citations: [String]) -> String {
        var text = withoutCitations(answer, citations: citations)
        text = withoutMarkdown(text)
        return tidied(text)
    }

    // ------------------------------------------------------------ citations

    static func withoutCitations(_ answer: String, citations: [String]) -> String {
        var text = answer
        // Back to front, so the ranges found in the original are still valid
        // while later text is removed.
        for hit in AnswerLinks.find(in: answer, citations: citations).reversed() {
            text.removeSubrange(hit.range)
        }
        // Whatever held the citation is now empty - "()", "[ ]", or "(, )"
        // where two were listed together - and is removed until none are left,
        // because emptying the inner pair can empty the outer one.
        var previous = ""
        while previous != text {
            previous = text
            text = text.replacing(#/[\(\[][\s,;]*[\)\]]/#, with: "")
        }
        return text
    }

    // ------------------------------------------------------------- markdown

    static func withoutMarkdown(_ text: String) -> String {
        var lines: [String] = []
        for raw in text.components(separatedBy: .newlines) {
            var line = raw
            // A fence is layout, not content. The code inside it is kept: an
            // answer that quotes a command is answering with that command.
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { continue }
            line = line.replacing(#/^\s*#{1,6}\s+/#, with: "")
            line = line.replacing(#/^\s*[-*+]\s+/#, with: "")
            line = line.replacing(#/^\s*>\s?/#, with: "")
            lines.append(line)
        }
        var out = lines.joined(separator: "\n")
        // [words](address) is read as its words; a bare address is not read at
        // all, because nobody listening can follow it and it takes longer to
        // say than the sentence around it.
        out = out.replacing(#/\[([^\]]+)\]\([^)]*\)/#) { String($0.output.1) }
        out = out.replacing(#/https?:\/\/\S+/#, with: "")
        out = out.replacing("**", with: "")
        out = out.replacing("__", with: "")
        out = out.replacing("`", with: "")
        out = out.replacing("*", with: "")
        // A table row read cell by cell, with a pause between cells.
        out = out.replacing(#/^\s*\|?[\s:|-]+\|?\s*$/#.anchorsMatchLineEndings(), with: "")
        out = out.replacing("|", with: ", ")
        return out
    }

    // ---------------------------------------------------------------- tidy

    static func tidied(_ text: String) -> String {
        var lines: [String] = []
        for raw in text.components(separatedBy: .newlines) {
            var line = raw.replacing(#/[ \t]+/#, with: " ")
            // What a removal left behind: " ." and " ," read as a pause before
            // nothing, and a leading comma as a cough.
            line = line.replacing(#/\s+([.,;:!?])/#) { String($0.output.1) }
            line = line.replacing(#/^[\s,;]+/#, with: "")
            line = line.replacing(#/[\s,;]+$/#, with: "")
            line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            // A list item with no full stop runs straight into the next one
            // when spoken. The full stop is the pause a reader's eye takes at
            // the line break.
            if let last = line.last, !".!?:;".contains(last) { line += "." }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }
}
