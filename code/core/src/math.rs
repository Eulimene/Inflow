//! Small, deterministic TeX subset rendered as safe `MathML`.

use std::iter::Peekable;
use std::str::Chars;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum MathError {
    UnsupportedCommand,
    InvalidSyntax,
}

pub fn mathml(source: &str, display: bool) -> Result<String, MathError> {
    let mut parser = MathParser::new(source);
    let body = parser.parse_expression(None);
    if let Some(error) = parser.error {
        return Err(error);
    }
    let display = if display { "block" } else { "inline" };
    Ok(format!(
        "<math xmlns=\"http://www.w3.org/1998/Math/MathML\" display=\"{display}\" aria-label=\"数学公式：{}\"><mrow>{body}</mrow></math>",
        escape(source)
    ))
}

struct MathParser<'a> {
    input: Peekable<Chars<'a>>,
    error: Option<MathError>,
}

impl<'a> MathParser<'a> {
    fn new(source: &'a str) -> Self {
        Self {
            input: source.chars().peekable(),
            error: None,
        }
    }

    fn parse_expression(&mut self, terminator: Option<char>) -> String {
        let mut output = String::new();
        let mut found_terminator = terminator.is_none();
        while let Some(character) = self.input.peek().copied() {
            if Some(character) == terminator {
                self.input.next();
                found_terminator = true;
                break;
            }
            if character.is_whitespace() {
                self.input.next();
                continue;
            }

            let base = self.parse_atom();
            let mut subscript = None;
            let mut superscript = None;
            while let Some(marker @ ('_' | '^')) = self.input.peek().copied() {
                self.input.next();
                let argument = self.parse_script_argument();
                if marker == '_' {
                    subscript = Some(argument);
                } else {
                    superscript = Some(argument);
                }
            }
            match (subscript, superscript) {
                (Some(sub), Some(sup)) => {
                    output.push_str("<msubsup>");
                    output.push_str(&base);
                    output.push_str("<mrow>");
                    output.push_str(&sub);
                    output.push_str("</mrow><mrow>");
                    output.push_str(&sup);
                    output.push_str("</mrow></msubsup>");
                }
                (Some(sub), None) => {
                    output.push_str("<msub>");
                    output.push_str(&base);
                    output.push_str("<mrow>");
                    output.push_str(&sub);
                    output.push_str("</mrow></msub>");
                }
                (None, Some(sup)) => {
                    output.push_str("<msup>");
                    output.push_str(&base);
                    output.push_str("<mrow>");
                    output.push_str(&sup);
                    output.push_str("</mrow></msup>");
                }
                (None, None) => output.push_str(&base),
            }
        }
        if !found_terminator {
            self.set_error(MathError::InvalidSyntax);
        }
        output
    }

    fn parse_atom(&mut self) -> String {
        let Some(character) = self.input.next() else {
            self.set_error(MathError::InvalidSyntax);
            return String::new();
        };
        match character {
            '{' => format!("<mrow>{}</mrow>", self.parse_expression(Some('}'))),
            '}' => {
                self.set_error(MathError::InvalidSyntax);
                String::new()
            }
            '\\' => self.parse_command(),
            '0'..='9' | '.' => self.parse_number(character),
            '+' | '-' | '=' | '<' | '>' | '/' | '*' | '(' | ')' | '[' | ']' | ',' | ';' | ':'
            | '|' => format!("<mo>{}</mo>", escape(&character.to_string())),
            other => format!("<mi>{}</mi>", escape(&other.to_string())),
        }
    }

    fn parse_number(&mut self, first: char) -> String {
        let mut number = first.to_string();
        while self
            .input
            .peek()
            .is_some_and(|character| character.is_ascii_digit() || *character == '.')
        {
            if let Some(character) = self.input.next() {
                number.push(character);
            }
        }
        format!("<mn>{}</mn>", escape(&number))
    }

    fn parse_command(&mut self) -> String {
        let mut command = String::new();
        while self.input.peek().is_some_and(char::is_ascii_alphabetic) {
            if let Some(character) = self.input.next() {
                command.push(character);
            }
        }
        if command.is_empty() {
            let literal = self.input.next().unwrap_or('\\');
            return format!("<mo>{}</mo>", escape(&literal.to_string()));
        }

        match command.as_str() {
            "frac" => {
                let numerator = self.parse_required_group();
                let denominator = self.parse_required_group();
                format!("<mfrac><mrow>{numerator}</mrow><mrow>{denominator}</mrow></mfrac>")
            }
            "sqrt" => format!(
                "<msqrt><mrow>{}</mrow></msqrt>",
                self.parse_required_group()
            ),
            "text" => format!("<mtext>{}</mtext>", escape(&self.parse_raw_group())),
            "left" | "right" => self.parse_stretchy_delimiter(),
            "sin" | "cos" | "tan" | "log" | "ln" | "exp" | "lim" | "max" | "min" => {
                format!("<mi mathvariant=\"normal\">{command}</mi>")
            }
            _ => command_symbol(&command).map_or_else(
                || {
                    self.set_error(MathError::UnsupportedCommand);
                    String::new()
                },
                |symbol| format!("<mo>{}</mo>", escape(symbol)),
            ),
        }
    }

    fn parse_required_group(&mut self) -> String {
        if self.input.next_if_eq(&'{').is_some() {
            self.parse_expression(Some('}'))
        } else {
            self.parse_atom()
        }
    }

    fn parse_raw_group(&mut self) -> String {
        if self.input.next_if_eq(&'{').is_none() {
            return self
                .input
                .next()
                .map_or_else(String::new, |value| value.to_string());
        }
        let mut depth = 1usize;
        let mut output = String::new();
        for character in self.input.by_ref() {
            match character {
                '{' => {
                    depth += 1;
                    output.push(character);
                }
                '}' => {
                    depth -= 1;
                    if depth == 0 {
                        break;
                    }
                    output.push(character);
                }
                _ => output.push(character),
            }
        }
        if depth != 0 {
            self.set_error(MathError::InvalidSyntax);
        }
        output
    }

    fn parse_stretchy_delimiter(&mut self) -> String {
        let delimiter = if self.input.next_if_eq(&'\\').is_some() {
            let mut name = String::new();
            while self.input.peek().is_some_and(char::is_ascii_alphabetic) {
                if let Some(character) = self.input.next() {
                    name.push(character);
                }
            }
            if let Some(symbol) = command_symbol(&name) {
                symbol.to_owned()
            } else {
                self.set_error(MathError::UnsupportedCommand);
                String::new()
            }
        } else if let Some(value) = self.input.next() {
            value.to_string()
        } else {
            self.set_error(MathError::InvalidSyntax);
            String::new()
        };
        format!("<mo stretchy=\"true\">{}</mo>", escape(&delimiter))
    }

    fn parse_script_argument(&mut self) -> String {
        if self.input.next_if_eq(&'{').is_some() {
            self.parse_expression(Some('}'))
        } else {
            self.parse_atom()
        }
    }

    fn set_error(&mut self, error: MathError) {
        if self.error.is_none() {
            self.error = Some(error);
        }
    }
}

pub fn fallback(
    source: &str,
    error: MathError,
    display: bool,
    source_range: Option<&std::ops::Range<usize>>,
) -> String {
    let reason = match error {
        MathError::UnsupportedCommand => "当前公式包含尚未支持的命令。",
        MathError::InvalidSyntax => "请检查分组、上下标和公式定界符。",
    };
    let attributes = source_range.map_or_else(String::new, |range| {
        format!(
            " data-inflow-source-start=\"{}\" data-inflow-source-end=\"{}\"",
            range.start, range.end
        )
    });
    let actions = if source_range.is_some() {
        "<span class=\"math-error-actions\"><button type=\"button\" data-inflow-preview-error-action=\"locate\">定位源文本</button><button type=\"button\" data-inflow-preview-error-action=\"retry\">重试</button></span>"
    } else {
        ""
    };
    let escaped_source = escape(source);
    if display {
        format!(
            "<figure class=\"math-error\" role=\"group\" aria-label=\"无法呈现这个公式\"{attributes}><figcaption><strong>无法呈现这个公式</strong><br>{reason}<br>原内容已保留，当前文档的其他内容和其他文档不受影响。</figcaption><pre><code>{escaped_source}</code></pre>{actions}</figure>"
        )
    } else {
        format!(
            "<span class=\"math-error math-error-inline\" role=\"group\" aria-label=\"无法呈现这个公式\"{attributes}><strong>无法呈现这个公式</strong><span>{reason} 原内容已保留，当前文档的其他内容和其他文档不受影响。</span><code>{escaped_source}</code>{actions}</span>"
        )
    }
}

fn command_symbol(command: &str) -> Option<&str> {
    Some(match command {
        "alpha" => "α",
        "beta" => "β",
        "gamma" => "γ",
        "delta" => "δ",
        "theta" => "θ",
        "lambda" => "λ",
        "mu" => "μ",
        "pi" => "π",
        "sigma" => "σ",
        "phi" => "φ",
        "omega" => "ω",
        "Gamma" => "Γ",
        "Delta" => "Δ",
        "Theta" => "Θ",
        "Lambda" => "Λ",
        "Pi" => "Π",
        "Sigma" => "Σ",
        "Phi" => "Φ",
        "Omega" => "Ω",
        "times" => "×",
        "cdot" => "·",
        "pm" => "±",
        "le" | "leq" => "≤",
        "ge" | "geq" => "≥",
        "ne" | "neq" => "≠",
        "in" => "∈",
        "notin" => "∉",
        "sum" => "∑",
        "prod" => "∏",
        "int" => "∫",
        "infty" => "∞",
        "to" | "rightarrow" => "→",
        "leftarrow" => "←",
        "leftrightarrow" => "↔",
        "langle" => "⟨",
        "rangle" => "⟩",
        _ => return None,
    })
}

fn escape(value: &str) -> String {
    value
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&#39;")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn renders_scripts_fraction_roots_and_greek_as_mathml() {
        let output = mathml(r"x_1^2 + \frac{\alpha}{\sqrt{y}}", false).unwrap();
        assert!(output.contains("display=\"inline\""));
        assert!(output.contains("<msubsup>"));
        assert!(output.contains("<mfrac>"));
        assert!(output.contains("<msqrt>"));
        assert!(output.contains("α"));
    }

    #[test]
    fn escapes_text_content_without_markup_execution() {
        let output = mathml(r"\text{<script>&} + \sin(x)", true).unwrap();
        assert!(output.contains("display=\"block\""));
        assert!(output.contains("&lt;script&gt;&amp;"));
        assert!(output.contains("mathvariant=\"normal\">sin"));
        assert!(!output.contains("<script>"));
    }

    #[test]
    fn rejects_unsupported_commands_and_unclosed_groups() {
        assert_eq!(
            mathml(r"\unknown{x}", false),
            Err(MathError::UnsupportedCommand)
        );
        assert_eq!(mathml(r"\frac{x}{y", true), Err(MathError::InvalidSyntax));
        assert_eq!(mathml("x^", false), Err(MathError::InvalidSyntax));
    }

    #[test]
    fn fallback_escapes_source_and_adds_actions_only_for_preview() {
        let preview = fallback(
            r"\unknown{<script>}",
            MathError::UnsupportedCommand,
            false,
            Some(&(7..29)),
        );
        assert!(preview.contains("无法呈现这个公式"));
        assert!(preview.contains("data-inflow-source-start=\"7\""));
        assert!(preview.contains("data-inflow-preview-error-action=\"locate\""));
        assert!(preview.contains("&lt;script&gt;"));
        assert!(!preview.contains("<script>"));

        let delivery = fallback(r"\unknown{x}", MathError::UnsupportedCommand, true, None);
        assert!(!delivery.contains("data-inflow-source-start"));
        assert!(!delivery.contains("<button"));
    }
}
