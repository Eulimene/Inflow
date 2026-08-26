//! Small, deterministic code-block highlighter for the launch preview surface.
//!
//! This intentionally recognizes a closed set of common language tags and
//! emits only escaped source plus fixed semantic classes. Unknown languages
//! remain ordinary readable code blocks through `pulldown-cmark`.

#[derive(Clone, Copy)]
enum LexerKind {
    General,
    Markup,
}

#[derive(Clone, Copy)]
struct LanguageProfile {
    canonical_name: &'static str,
    kind: LexerKind,
    keywords: &'static [&'static str],
    line_comment: Option<&'static str>,
    block_comment: Option<(&'static str, &'static str)>,
    quotes: &'static [u8],
    case_insensitive_keywords: bool,
}

pub(crate) fn highlighted_code_block(info: &str, source: &str) -> Option<String> {
    let name = info.split_ascii_whitespace().next()?;
    let profile = profile(name)?;
    let body = match profile.kind {
        LexerKind::General => highlight_general(source, profile),
        LexerKind::Markup => highlight_markup(source),
    };
    Some(format!(
        "<pre><code class=\"language-{} inflow-code-highlight\">{body}</code></pre>\n",
        profile.canonical_name
    ))
}

pub(crate) fn supports_language(info: &str) -> bool {
    info.split_ascii_whitespace()
        .next()
        .and_then(profile)
        .is_some()
}

#[allow(clippy::too_many_lines)] // The closed language table is clearer kept in one auditable match.
fn profile(name: &str) -> Option<LanguageProfile> {
    let lowered = name.to_ascii_lowercase();
    let (canonical_name, keywords, line_comment, block_comment, quotes, kind, insensitive) =
        match lowered.as_str() {
            "rust" | "rs" => (
                "rust",
                RUST_KEYWORDS,
                Some("//"),
                Some(("/*", "*/")),
                b"\"'".as_slice(),
                LexerKind::General,
                false,
            ),
            "swift" => (
                "swift",
                SWIFT_KEYWORDS,
                Some("//"),
                Some(("/*", "*/")),
                b"\"'".as_slice(),
                LexerKind::General,
                false,
            ),
            "javascript" | "js" | "jsx" => (
                "javascript",
                JAVASCRIPT_KEYWORDS,
                Some("//"),
                Some(("/*", "*/")),
                b"\"'`".as_slice(),
                LexerKind::General,
                false,
            ),
            "typescript" | "ts" | "tsx" => (
                "typescript",
                TYPESCRIPT_KEYWORDS,
                Some("//"),
                Some(("/*", "*/")),
                b"\"'`".as_slice(),
                LexerKind::General,
                false,
            ),
            "python" | "py" => (
                "python",
                PYTHON_KEYWORDS,
                Some("#"),
                None,
                b"\"'".as_slice(),
                LexerKind::General,
                false,
            ),
            "bash" | "sh" | "shell" | "zsh" => (
                "shell",
                SHELL_KEYWORDS,
                Some("#"),
                None,
                b"\"'`".as_slice(),
                LexerKind::General,
                false,
            ),
            "c" | "h" | "cpp" | "c++" | "cc" | "cxx" | "hpp" | "objective-c" | "objc" => (
                "cpp",
                C_FAMILY_KEYWORDS,
                Some("//"),
                Some(("/*", "*/")),
                b"\"'".as_slice(),
                LexerKind::General,
                false,
            ),
            "java" | "kotlin" | "kt" | "csharp" | "cs" => (
                "java",
                JVM_KEYWORDS,
                Some("//"),
                Some(("/*", "*/")),
                b"\"'".as_slice(),
                LexerKind::General,
                false,
            ),
            "go" | "golang" => (
                "go",
                GO_KEYWORDS,
                Some("//"),
                Some(("/*", "*/")),
                b"\"'`".as_slice(),
                LexerKind::General,
                false,
            ),
            "json" | "jsonc" => (
                "json",
                JSON_KEYWORDS,
                if lowered == "jsonc" { Some("//") } else { None },
                if lowered == "jsonc" {
                    Some(("/*", "*/"))
                } else {
                    None
                },
                b"\"".as_slice(),
                LexerKind::General,
                false,
            ),
            "sql" => (
                "sql",
                SQL_KEYWORDS,
                Some("--"),
                Some(("/*", "*/")),
                b"\"'`".as_slice(),
                LexerKind::General,
                true,
            ),
            "css" | "scss" | "sass" | "less" => (
                "css",
                CSS_KEYWORDS,
                None,
                Some(("/*", "*/")),
                b"\"'".as_slice(),
                LexerKind::General,
                false,
            ),
            "html" | "xml" | "svg" => (
                "html",
                EMPTY_KEYWORDS,
                None,
                None,
                EMPTY_BYTES,
                LexerKind::Markup,
                false,
            ),
            _ => return None,
        };
    Some(LanguageProfile {
        canonical_name,
        kind,
        keywords,
        line_comment,
        block_comment,
        quotes,
        case_insensitive_keywords: insensitive,
    })
}

fn highlight_general(source: &str, profile: LanguageProfile) -> String {
    let bytes = source.as_bytes();
    let mut output = String::with_capacity(source.len() + source.len() / 4);
    let mut index = 0;
    while index < bytes.len() {
        if let Some((start, end)) = profile.block_comment
            && starts_with(source, index, start)
        {
            let token_end = source[index + start.len()..]
                .find(end)
                .map_or(source.len(), |offset| {
                    index + start.len() + offset + end.len()
                });
            push_token(&mut output, "tok-comment", &source[index..token_end]);
            index = token_end;
            continue;
        }
        if let Some(marker) = profile.line_comment
            && starts_with(source, index, marker)
        {
            let token_end = source[index..]
                .find('\n')
                .map_or(source.len(), |offset| index + offset);
            push_token(&mut output, "tok-comment", &source[index..token_end]);
            index = token_end;
            continue;
        }
        if bytes[index].is_ascii() && profile.quotes.contains(&bytes[index]) {
            let quote = bytes[index];
            let mut token_end = index + 1;
            let mut escaped = false;
            while token_end < bytes.len() {
                let byte = bytes[token_end];
                token_end += 1;
                if escaped {
                    escaped = false;
                } else if byte == b'\\' {
                    escaped = true;
                } else if byte == quote {
                    break;
                }
            }
            push_token(&mut output, "tok-string", &source[index..token_end]);
            index = token_end;
            continue;
        }
        if bytes[index].is_ascii_digit() {
            let mut token_end = index + 1;
            while token_end < bytes.len()
                && (bytes[token_end].is_ascii_alphanumeric()
                    || matches!(bytes[token_end], b'.' | b'_' | b'+' | b'-'))
            {
                token_end += 1;
            }
            push_token(&mut output, "tok-number", &source[index..token_end]);
            index = token_end;
            continue;
        }
        if is_identifier_start(bytes[index]) {
            let mut token_end = index + 1;
            while token_end < bytes.len() && is_identifier_continue(bytes[token_end]) {
                token_end += 1;
            }
            let identifier = &source[index..token_end];
            if is_keyword(identifier, profile) {
                push_token(&mut output, "tok-keyword", identifier);
            } else if is_literal(identifier) {
                push_token(&mut output, "tok-literal", identifier);
            } else if identifier.as_bytes()[0].is_ascii_uppercase() {
                push_token(&mut output, "tok-type", identifier);
            } else {
                push_escaped(&mut output, identifier);
            }
            index = token_end;
            continue;
        }

        let character = source[index..]
            .chars()
            .next()
            .expect("index remains on a UTF-8 character boundary");
        let token_end = index + character.len_utf8();
        push_escaped(&mut output, &source[index..token_end]);
        index = token_end;
    }
    output
}

fn highlight_markup(source: &str) -> String {
    let mut output = String::with_capacity(source.len() + source.len() / 4);
    let mut index = 0;
    while index < source.len() {
        if starts_with(source, index, "<!--") {
            let end = source[index + 4..]
                .find("-->")
                .map_or(source.len(), |offset| index + 4 + offset + 3);
            push_token(&mut output, "tok-comment", &source[index..end]);
            index = end;
            continue;
        }
        if starts_with(source, index, "<") {
            let end = source[index..]
                .find('>')
                .map_or(source.len(), |offset| index + offset + 1);
            push_token(&mut output, "tok-tag", &source[index..end]);
            index = end;
            continue;
        }
        let next = source[index..]
            .find('<')
            .map_or(source.len(), |offset| index + offset);
        push_escaped(&mut output, &source[index..next]);
        index = next;
    }
    output
}

fn starts_with(source: &str, index: usize, marker: &str) -> bool {
    source.as_bytes()[index..].starts_with(marker.as_bytes())
}

fn is_identifier_start(byte: u8) -> bool {
    byte.is_ascii_alphabetic() || matches!(byte, b'_' | b'$')
}

fn is_identifier_continue(byte: u8) -> bool {
    byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'$')
}

fn is_keyword(identifier: &str, profile: LanguageProfile) -> bool {
    profile.keywords.iter().any(|keyword| {
        if profile.case_insensitive_keywords {
            identifier.eq_ignore_ascii_case(keyword)
        } else {
            identifier == *keyword
        }
    })
}

fn is_literal(identifier: &str) -> bool {
    ["true", "false", "null", "nil", "None", "undefined"].contains(&identifier)
}

fn push_token(output: &mut String, class_name: &str, source: &str) {
    output.push_str("<span class=\"");
    output.push_str(class_name);
    output.push_str("\">");
    push_escaped(output, source);
    output.push_str("</span>");
}

fn push_escaped(output: &mut String, source: &str) {
    for character in source.chars() {
        match character {
            '&' => output.push_str("&amp;"),
            '<' => output.push_str("&lt;"),
            '>' => output.push_str("&gt;"),
            '"' => output.push_str("&quot;"),
            '\'' => output.push_str("&#39;"),
            other => output.push(other),
        }
    }
}

const EMPTY_BYTES: &[u8] = b"";
const EMPTY_KEYWORDS: &[&str] = &[];
const RUST_KEYWORDS: &[&str] = &[
    "as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum", "extern",
    "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub", "ref",
    "return", "self", "Self", "static", "struct", "super", "trait", "type", "unsafe", "use",
    "where", "while",
];
const SWIFT_KEYWORDS: &[&str] = &[
    "actor",
    "as",
    "associatedtype",
    "async",
    "await",
    "break",
    "case",
    "catch",
    "class",
    "continue",
    "default",
    "defer",
    "deinit",
    "do",
    "else",
    "enum",
    "extension",
    "fallthrough",
    "for",
    "func",
    "guard",
    "if",
    "import",
    "in",
    "init",
    "inout",
    "internal",
    "is",
    "let",
    "nonisolated",
    "open",
    "operator",
    "private",
    "protocol",
    "public",
    "repeat",
    "rethrows",
    "return",
    "some",
    "static",
    "struct",
    "subscript",
    "switch",
    "throw",
    "throws",
    "try",
    "typealias",
    "var",
    "where",
    "while",
];
const JAVASCRIPT_KEYWORDS: &[&str] = &[
    "async",
    "await",
    "break",
    "case",
    "catch",
    "class",
    "const",
    "continue",
    "debugger",
    "default",
    "delete",
    "do",
    "else",
    "export",
    "extends",
    "finally",
    "for",
    "function",
    "if",
    "import",
    "in",
    "instanceof",
    "let",
    "new",
    "return",
    "static",
    "super",
    "switch",
    "this",
    "throw",
    "try",
    "typeof",
    "var",
    "void",
    "while",
    "with",
    "yield",
];
const TYPESCRIPT_KEYWORDS: &[&str] = &[
    "abstract",
    "any",
    "as",
    "async",
    "await",
    "boolean",
    "break",
    "case",
    "catch",
    "class",
    "const",
    "continue",
    "declare",
    "default",
    "delete",
    "do",
    "else",
    "enum",
    "export",
    "extends",
    "finally",
    "for",
    "from",
    "function",
    "if",
    "implements",
    "import",
    "in",
    "instanceof",
    "interface",
    "keyof",
    "let",
    "namespace",
    "never",
    "new",
    "number",
    "object",
    "private",
    "protected",
    "public",
    "readonly",
    "return",
    "static",
    "string",
    "super",
    "switch",
    "this",
    "throw",
    "try",
    "type",
    "typeof",
    "undefined",
    "unknown",
    "var",
    "void",
    "while",
    "yield",
];
const PYTHON_KEYWORDS: &[&str] = &[
    "and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif",
    "else", "except", "finally", "for", "from", "global", "if", "import", "in", "is", "lambda",
    "nonlocal", "not", "or", "pass", "raise", "return", "try", "while", "with", "yield",
];
const SHELL_KEYWORDS: &[&str] = &[
    "case", "do", "done", "elif", "else", "esac", "export", "fi", "for", "function", "if", "in",
    "local", "readonly", "return", "select", "then", "until", "while",
];
const C_FAMILY_KEYWORDS: &[&str] = &[
    "alignas",
    "alignof",
    "auto",
    "bool",
    "break",
    "case",
    "catch",
    "char",
    "class",
    "const",
    "constexpr",
    "continue",
    "default",
    "delete",
    "do",
    "double",
    "else",
    "enum",
    "explicit",
    "extern",
    "false",
    "float",
    "for",
    "friend",
    "if",
    "inline",
    "int",
    "long",
    "namespace",
    "new",
    "nullptr",
    "operator",
    "private",
    "protected",
    "public",
    "return",
    "short",
    "signed",
    "sizeof",
    "static",
    "struct",
    "switch",
    "template",
    "this",
    "throw",
    "true",
    "try",
    "typedef",
    "typename",
    "union",
    "unsigned",
    "using",
    "virtual",
    "void",
    "volatile",
    "while",
];
const JVM_KEYWORDS: &[&str] = &[
    "abstract",
    "as",
    "assert",
    "boolean",
    "break",
    "byte",
    "case",
    "catch",
    "char",
    "class",
    "const",
    "continue",
    "data",
    "default",
    "do",
    "double",
    "else",
    "enum",
    "extends",
    "final",
    "finally",
    "float",
    "for",
    "fun",
    "if",
    "implements",
    "import",
    "in",
    "instanceof",
    "int",
    "interface",
    "internal",
    "is",
    "long",
    "native",
    "new",
    "null",
    "object",
    "open",
    "override",
    "package",
    "private",
    "protected",
    "public",
    "return",
    "sealed",
    "short",
    "static",
    "strictfp",
    "super",
    "switch",
    "synchronized",
    "this",
    "throw",
    "throws",
    "transient",
    "try",
    "val",
    "var",
    "void",
    "volatile",
    "when",
    "while",
];
const GO_KEYWORDS: &[&str] = &[
    "break",
    "case",
    "chan",
    "const",
    "continue",
    "default",
    "defer",
    "else",
    "fallthrough",
    "for",
    "func",
    "go",
    "goto",
    "if",
    "import",
    "interface",
    "map",
    "package",
    "range",
    "return",
    "select",
    "struct",
    "switch",
    "type",
    "var",
];
const JSON_KEYWORDS: &[&str] = &[];
const SQL_KEYWORDS: &[&str] = &[
    "add",
    "all",
    "alter",
    "and",
    "as",
    "asc",
    "between",
    "by",
    "case",
    "check",
    "column",
    "create",
    "database",
    "default",
    "delete",
    "desc",
    "distinct",
    "drop",
    "else",
    "end",
    "exists",
    "foreign",
    "from",
    "full",
    "group",
    "having",
    "in",
    "index",
    "inner",
    "insert",
    "into",
    "is",
    "join",
    "key",
    "left",
    "like",
    "limit",
    "not",
    "null",
    "on",
    "or",
    "order",
    "outer",
    "primary",
    "references",
    "right",
    "select",
    "set",
    "table",
    "then",
    "union",
    "unique",
    "update",
    "values",
    "view",
    "when",
    "where",
];
const CSS_KEYWORDS: &[&str] = &[
    "important",
    "inherit",
    "initial",
    "none",
    "revert",
    "transparent",
    "unset",
    "var",
];

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn highlights_common_rust_tokens_and_preserves_unicode() {
        let html = highlighted_code_block(
            "rust extra-info",
            "fn main() { let value: Option<&str> = Some(\"你好\"); // note\n}\n",
        )
        .expect("rust is supported");

        assert!(html.starts_with("<pre><code class=\"language-rust inflow-code-highlight\">"));
        assert!(html.contains("<span class=\"tok-keyword\">fn</span>"));
        assert!(html.contains("<span class=\"tok-type\">Option</span>&lt;"));
        assert!(html.contains("<span class=\"tok-string\">&quot;你好&quot;</span>"));
        assert!(html.contains("<span class=\"tok-comment\">// note</span>"));
        assert!(html.ends_with("</code></pre>\n"));
    }

    #[test]
    fn escaped_code_can_never_become_executable_markup() {
        let html = highlighted_code_block(
            "html",
            "<script data-value=\"x\">alert('no')</script><!-- note -->",
        )
        .expect("html is supported");

        assert!(!html.contains("<script"));
        assert!(html.contains("&lt;script data-value=&quot;x&quot;&gt;"));
        assert!(html.contains("<span class=\"tok-comment\">&lt;!-- note --&gt;</span>"));
    }

    #[test]
    fn unknown_language_is_left_to_the_markdown_renderer() {
        assert!(highlighted_code_block("brainfuck", "+[--]").is_none());
        assert!(highlighted_code_block("", "plain").is_none());
        assert!(!supports_language("brainfuck"));
        assert!(supports_language("Swift linenos"));
    }
}
