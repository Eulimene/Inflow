//! Small, deterministic TeX subset rendered as safe `MathML`.

use std::iter::Peekable;
use std::str::Chars;

pub fn mathml(source: &str, display: bool) -> String {
    let body = MathParser::new(source).parse_expression(None);
    let display = if display { "block" } else { "inline" };
    format!(
        "<math xmlns=\"http://www.w3.org/1998/Math/MathML\" display=\"{display}\" aria-label=\"数学公式：{}\"><mrow>{body}</mrow></math>",
        escape(source)
    )
}

struct MathParser<'a> {
    input: Peekable<Chars<'a>>,
}

impl<'a> MathParser<'a> {
    fn new(source: &'a str) -> Self {
        Self {
            input: source.chars().peekable(),
        }
    }

    fn parse_expression(&mut self, terminator: Option<char>) -> String {
        let mut output = String::new();
        while let Some(character) = self.input.peek().copied() {
            if Some(character) == terminator {
                self.input.next();
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
        output
    }

    fn parse_atom(&mut self) -> String {
        let Some(character) = self.input.next() else {
            return String::new();
        };
        match character {
            '{' => format!("<mrow>{}</mrow>", self.parse_expression(Some('}'))),
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
            _ => command_symbol(&command).map_or_else(
                || format!("<mtext>\\{}</mtext>", escape(&command)),
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
            command_symbol(&name).unwrap_or(&name).to_owned()
        } else {
            self.input
                .next()
                .map_or_else(String::new, |value| value.to_string())
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
        let output = mathml(r"x_1^2 + \frac{\alpha}{\sqrt{y}}", false);
        assert!(output.contains("display=\"inline\""));
        assert!(output.contains("<msubsup>"));
        assert!(output.contains("<mfrac>"));
        assert!(output.contains("<msqrt>"));
        assert!(output.contains("α"));
    }

    #[test]
    fn escapes_unknown_and_text_content_without_markup_execution() {
        let output = mathml(r"\text{<script>&} + \unknown", true);
        assert!(output.contains("display=\"block\""));
        assert!(output.contains("&lt;script&gt;&amp;"));
        assert!(output.contains(r"\unknown"));
        assert!(!output.contains("<script>"));
    }
}
