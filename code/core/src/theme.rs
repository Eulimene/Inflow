//! Immutable, bounded theme compiler shared by all hosts.
//! Profile 0 preserves shipped themes during the migration to a semantic style tree.
use crate::theme_values::{self, Length};
use cssparser::{
    AtRuleParser, CowRcStr, DeclarationParser, ParseError, Parser, ParserState,
    QualifiedRuleParser, RuleBodyItemParser, RuleBodyParser, StyleSheetParser, Token,
};
use serde::Serialize;
use std::collections::{BTreeMap, BTreeSet, VecDeque};
use std::sync::{Arc, Mutex, OnceLock};

const MAX_CSS_BYTES: usize = 256 * 1024;
const MAX_RULES: usize = 8192;
const CACHE_BYTES: usize = 4 * 1024 * 1024;
const ROOTS: [&str; 4] = [":root", "html", "body", "#write"];
const ELEMENTS: &[&str] = &[
    ":root",
    "html",
    "body",
    "#write",
    "p",
    "h1",
    "h2",
    "h3",
    "h4",
    "h5",
    "h6",
    "h1+h2",
    "h2+h3",
    "h1:first-child",
    "h2:first-child",
    "a",
    "blockquote",
    "pre",
    "code",
    "table",
    "th",
    "td",
    "tr:nth-child(even)",
    "tr:nth-child(2n)",
    "strong",
    "em",
    "li",
    "ul",
    "ol",
    "hr",
    "math",
    "::selection",
    "#write::selection",
];

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct Rule {
    pub selector: String,
    pub property: String,
    pub value: String,
    pub priority: u32,
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct Diagnostic {
    pub code: String,
    pub line: u32,
    pub column: u32,
}
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct ThemeSnapshot {
    pub profile_version: u32,
    pub resolved_css: String,
    pub rules: Vec<Rule>,
    pub is_valid: bool,
    pub has_unsupported_rules: bool,
    pub diagnostics: Vec<Diagnostic>,
    pub values: BTreeMap<String, BTreeMap<String, String>>,
    pub lengths: BTreeMap<String, BTreeMap<String, Length>>,
    pub colors: BTreeMap<String, String>,
    pub fonts: BTreeMap<String, Vec<String>>,
}

struct CacheEntry {
    css: String,
    dark: bool,
    snapshot: Arc<ThemeSnapshot>,
    bytes: usize,
}
static CACHE: OnceLock<Mutex<VecDeque<CacheEntry>>> = OnceLock::new();

#[cfg(test)]
pub fn compile(css: &str) -> Arc<ThemeSnapshot> {
    compile_for_scheme(css, false)
}

pub fn compile_for_scheme(css: &str, dark: bool) -> Arc<ThemeSnapshot> {
    let cache = CACHE.get_or_init(|| Mutex::new(VecDeque::new()));
    if let Ok(mut entries) = cache.lock()
        && let Some(index) = entries.iter().position(|e| e.css == css && e.dark == dark)
    {
        let entry = entries.remove(index).expect("index exists");
        let result = Arc::clone(&entry.snapshot);
        entries.push_back(entry);
        return result;
    }
    // Compilation never holds the global cache lock.
    let snapshot = Arc::new(compile_uncached(css, dark));
    let bytes = css.len() + serde_json::to_vec(snapshot.as_ref()).map_or(0, |v| v.len());
    if snapshot.is_valid
        && bytes <= CACHE_BYTES
        && let Ok(mut entries) = cache.lock()
    {
        while entries.iter().map(|e| e.bytes).sum::<usize>() + bytes > CACHE_BYTES {
            entries.pop_front();
        }
        entries.push_back(CacheEntry {
            css: css.into(),
            dark,
            snapshot: Arc::clone(&snapshot),
            bytes,
        });
    }
    snapshot
}

fn compile_uncached(css: &str, dark: bool) -> ThemeSnapshot {
    let mut sheet = Sheet::default();
    if css.len() > MAX_CSS_BYTES || !balanced(css) {
        sheet.diagnostics.push(Diagnostic {
            code: "invalid_or_oversized_css".into(),
            line: 1,
            column: 1,
        });
        return snapshot(Vec::new(), false, sheet.diagnostics);
    }
    let Ok(resolved_css) = resolve_appearance(css, dark, 0) else {
        return snapshot(
            Vec::new(),
            false,
            vec![Diagnostic {
                code: "invalid_appearance_rules".into(),
                line: 1,
                column: 1,
            }],
        );
    };
    let mut parser = Parser::new(&resolved_css);
    let mut rules = Vec::new();
    let mut parse_diagnostics = Vec::new();
    for result in StyleSheetParser::new(&mut parser, &mut sheet) {
        match result {
            Ok(mut values) => rules.append(&mut values),
            Err((_, _, location)) => {
                parse_diagnostics.push(Diagnostic {
                    code: "unsupported_rule".into(),
                    line: location.line + 1,
                    column: location.column,
                });
            }
        }
        if rules.len() > MAX_RULES {
            return snapshot(
                Vec::new(),
                false,
                vec![Diagnostic {
                    code: "rule_budget_exceeded".into(),
                    line: 1,
                    column: 1,
                }],
            );
        }
    }
    sheet.diagnostics.extend(parse_diagnostics);
    let valid = !rules.is_empty();
    let mut result = snapshot(rules, valid, sheet.diagnostics);
    drop(parser);
    result.resolved_css = resolved_css;
    result
}

fn snapshot(rules: Vec<Rule>, valid: bool, diagnostics: Vec<Diagnostic>) -> ThemeSnapshot {
    let mut variables: BTreeMap<&str, &Rule> = BTreeMap::new();
    for rule in &rules {
        if ROOTS.contains(&rule.selector.as_str())
            && rule.property.starts_with("--")
            && variables
                .get(rule.property.as_str())
                .is_none_or(|prior| prior.priority <= rule.priority)
        {
            variables.insert(&rule.property, rule);
        }
    }
    let mut elements: BTreeSet<String> = BTreeSet::from(["body".into()]);
    for rule in &rules {
        elements.insert(rule.selector.clone());
        if let Some(element) = rule.selector.strip_prefix("#write ") {
            elements.insert(element.into());
        }
        if rule.selector == "#write::selection" {
            elements.insert("::selection".into());
        }
    }
    let mut budget = 32768usize;
    let mut output_bytes = 0;
    let mut values = BTreeMap::new();
    let mut lengths = BTreeMap::new();
    let mut colors = BTreeMap::new();
    let mut fonts = BTreeMap::new();
    for element in elements {
        let scoped = format!("#write {element}");
        let mut winners: BTreeMap<&str, &Rule> = BTreeMap::new();
        for rule in &rules {
            let matches = if element == "body" {
                ROOTS.contains(&rule.selector.as_str())
            } else {
                rule.selector == element
                    || rule.selector == scoped
                    || (element == "::selection" && rule.selector == "#write::selection")
            };
            if !matches {
                continue;
            }
            if let Some(prior) = winners.get(rule.property.as_str()) {
                let previous_scope = ["body", "#write"].contains(&prior.selector.as_str());
                let scope = ["body", "#write"].contains(&rule.selector.as_str());
                if element == "body" && previous_scope != scope {
                    if previous_scope {
                        continue;
                    }
                } else if prior.priority > rule.priority {
                    continue;
                }
            }
            winners.insert(&rule.property, rule);
        }
        let resolved: BTreeMap<String, String> = winners
            .into_iter()
            .filter_map(|(name, rule)| {
                resolve(&rule.value, &variables, 0, &mut budget).map(|value| (name.into(), value))
            })
            .collect();
        output_bytes += resolved
            .iter()
            .map(|(k, v)| k.len() + v.len())
            .sum::<usize>();
        if budget == 0 || output_bytes > CACHE_BYTES {
            return snapshot(
                Vec::new(),
                false,
                vec![Diagnostic {
                    code: "expansion_budget_exceeded".into(),
                    line: 1,
                    column: 1,
                }],
            );
        }
        lengths.insert(
            element.clone(),
            resolved
                .iter()
                .filter_map(|(key, value)| theme_values::length(value).map(|v| (key.clone(), v)))
                .collect(),
        );
        collect_colors(&resolved, &mut colors);
        if let Some(family) = resolved.get("font-family") {
            fonts.insert(element.clone(), theme_values::font_families(family));
        }
        values.insert(element, resolved);
    }
    ThemeSnapshot {
        profile_version: 0,
        resolved_css: String::new(),
        rules,
        is_valid: valid,
        has_unsupported_rules: !diagnostics.is_empty(),
        diagnostics,
        values,
        lengths,
        colors,
        fonts,
    }
}

fn collect_colors(values: &BTreeMap<String, String>, colors: &mut BTreeMap<String, String>) {
    for value in values.values() {
        if let Some(color) = theme_values::color(value) {
            colors.insert(value.clone(), color);
        }
    }
}

fn resolve(
    raw: &str,
    variables: &BTreeMap<&str, &Rule>,
    depth: usize,
    budget: &mut usize,
) -> Option<String> {
    if *budget == 0 || depth >= 32 || raw.len() > MAX_CSS_BYTES {
        return None;
    }
    *budget -= 1;
    let mut input = Parser::new(raw);
    resolve_tokens(&mut input, variables, depth, budget)
}
fn resolve_tokens(
    input: &mut Parser<'_>,
    variables: &BTreeMap<&str, &Rule>,
    depth: usize,
    budget: &mut usize,
) -> Option<String> {
    use cssparser::ToCss;
    if depth >= 32 {
        return None;
    }
    let mut output = String::new();
    while !input.is_exhausted() {
        let token = input.next_including_whitespace_and_comments().ok()?.clone();
        match token {
            Token::Comment(_) => output.push(' '),
            Token::Function(ref name) if name.eq_ignore_ascii_case("var") => {
                let replacement = input
                    .parse_nested_block(|p| {
                        let name = p.expect_ident_cloned()?;
                        let fallback = if p.try_parse(Parser::expect_comma).is_ok() {
                            resolve_tokens(p, variables, depth + 1, budget)
                        } else {
                            None
                        };
                        variables
                            .get(name.as_ref())
                            .and_then(|r| resolve(&r.value, variables, depth + 1, budget))
                            .or(fallback)
                            .ok_or_else(|| cssparser::ParseError::<()>::custom(()))
                    })
                    .ok()?;
                output.push_str(&replacement);
            }
            Token::Function(_) | Token::ParenthesisBlock => {
                output.push_str(&token.to_css_string());
                let inside = input
                    .parse_nested_block(|p| {
                        resolve_tokens(p, variables, depth + 1, budget)
                            .ok_or_else(|| cssparser::ParseError::<()>::custom(()))
                    })
                    .ok()?;
                output.push_str(&inside);
                output.push(')');
            }
            _ => output.push_str(&token.to_css_string()),
        }
        if output.len() > MAX_CSS_BYTES {
            return None;
        }
    }
    Some(output.trim().into())
}

#[derive(Default)]
struct Sheet {
    diagnostics: Vec<Diagnostic>,
}
impl AtRuleParser<'_> for Sheet {
    type Prelude = ();
    type AtRule = Vec<Rule>;
    type Error = ();
}
impl<'i> QualifiedRuleParser<'i> for Sheet {
    type Prelude = Vec<String>;
    type QualifiedRule = Vec<Rule>;
    type Error = ();
    fn parse_prelude(&mut self, p: &mut Parser<'i>) -> Result<Self::Prelude, ParseError<()>> {
        p.parse_comma_separated(|p| {
            use cssparser::ToCss;
            let mut selector = String::new();
            while let Ok(token) = p.next_including_whitespace_and_comments() {
                let token = token.clone();
                match token {
                    Token::Comment(_) => selector.push(' '),
                    Token::Function(_) => {
                        selector.push_str(&token.to_css_string());
                        let start = p.position();
                        let value = p.parse_nested_block(|inner| {
                            while inner.next().is_ok() {}
                            Ok::<_, ParseError<()>>(inner.slice_from(start).to_owned())
                        })?;
                        selector.push_str(&value);
                        selector.push(')');
                    }
                    _ => selector.push_str(&token.to_css_string()),
                }
            }
            let selector = selector
                .split_whitespace()
                .collect::<Vec<_>>()
                .join(" ")
                .replace(" + ", "+");
            let element = selector.strip_prefix("#write ").unwrap_or(&selector);
            if !ELEMENTS.contains(&element) {
                return Err(cssparser::ParseError::<()>::custom(()));
            }
            Ok(selector)
        })
    }
    fn parse_block(
        &mut self,
        selectors: Vec<String>,
        _: &ParserState,
        p: &mut Parser<'i>,
    ) -> Result<Vec<Rule>, ParseError<()>> {
        let mut declarations = Declarations;
        let mut rules = Vec::new();
        for declaration in RuleBodyParser::new(p, &mut declarations) {
            match declaration {
                Ok((property, value, important)) => {
                    for selector in &selectors {
                        let priority = u32::from(important) * 1000
                            + if selector.contains("#write") {
                                100
                            } else if selector == ":root" {
                                10
                            } else {
                                1
                            };
                        for (name, value) in expand(&property, &value) {
                            if rules.len() >= MAX_RULES {
                                return Err(cssparser::ParseError::<()>::custom(()));
                            }
                            rules.push(Rule {
                                selector: selector.clone(),
                                property: name,
                                value,
                                priority,
                            });
                        }
                    }
                }
                Err((_, _, location)) => self.diagnostics.push(Diagnostic {
                    code: "invalid_declaration".into(),
                    line: location.line + 1,
                    column: location.column,
                }),
            }
        }
        Ok(rules)
    }
}
struct Declarations;
type Declaration = (String, String, bool);
impl<'i> DeclarationParser<'i> for Declarations {
    type Declaration = Declaration;
    type Error = ();
    fn parse_value(
        &mut self,
        name: CowRcStr<'i>,
        p: &mut Parser<'i>,
        _: &ParserState,
    ) -> Result<Declaration, ParseError<()>> {
        let start = p.position();
        let mut important_start = None;
        while !p.is_exhausted() {
            let position = p.position();
            if p.try_parse(cssparser::parse_important).is_ok() {
                p.expect_exhausted()?;
                important_start = Some(position);
                break;
            }
            let token = p.next()?.clone();
            if matches!(
                token,
                Token::Function(_)
                    | Token::ParenthesisBlock
                    | Token::SquareBracketBlock
                    | Token::CurlyBracketBlock
            ) {
                p.parse_nested_block(consume_tokens)?;
            }
        }
        let value = if let Some(end) = important_start {
            p.slice(start..end)
        } else {
            p.slice_from(start)
        }
        .trim()
        .to_owned();
        if value.is_empty() {
            return Err(cssparser::ParseError::<()>::custom(()));
        }
        let name = if name.starts_with("--") {
            name.to_string()
        } else {
            name.to_ascii_lowercase()
        };
        Ok((name, value, important_start.is_some()))
    }
}
impl AtRuleParser<'_> for Declarations {
    type Prelude = ();
    type AtRule = Declaration;
    type Error = ();
}
impl QualifiedRuleParser<'_> for Declarations {
    type Prelude = ();
    type QualifiedRule = Declaration;
    type Error = ();
}
impl RuleBodyItemParser<'_, Declaration, ()> for Declarations {
    fn parse_declarations(&self) -> bool {
        true
    }
    fn parse_qualified(&self) -> bool {
        false
    }
}
fn consume_tokens(p: &mut Parser<'_>) -> Result<(), ParseError<()>> {
    while !p.is_exhausted() {
        let token = p.next()?.clone();
        if matches!(
            token,
            Token::Function(_)
                | Token::ParenthesisBlock
                | Token::SquareBracketBlock
                | Token::CurlyBracketBlock
        ) {
            p.parse_nested_block(consume_tokens)?;
        }
    }
    Ok(())
}
fn expand(property: &str, value: &str) -> Vec<(String, String)> {
    let mut result = vec![(property.into(), value.into())];
    let parts: Vec<_> = value.split_whitespace().collect();
    if ["margin", "padding"].contains(&property) && (1..=4).contains(&parts.len()) {
        let sides = [
            parts[0],
            *parts.get(1).unwrap_or(&parts[0]),
            *parts.get(2).unwrap_or(&parts[0]),
            *parts.get(3).or(parts.get(1)).unwrap_or(&parts[0]),
        ];
        for (side, value) in ["top", "right", "bottom", "left"].iter().zip(sides) {
            result.push((format!("{property}-{side}"), value.into()));
        }
    }
    if [
        "border",
        "border-left",
        "border-right",
        "border-bottom",
        "border-top",
    ]
    .contains(&property)
    {
        if let Some(first) = parts.first() {
            result.push((
                format!("{property}-width"),
                if ["none", "hidden"].contains(first) {
                    "0"
                } else {
                    first
                }
                .into(),
            ));
        }
        if let Some(last) = parts.last() {
            result.push((format!("{property}-color"), (*last).into()));
        }
    }
    result
}

// Strict editor-file validation in addition to CSS's permissive EOF recovery.
fn balanced(css: &str) -> bool {
    let mut chars = css.chars().peekable();
    let mut stack = Vec::new();
    let mut quote = None;
    while let Some(c) = chars.next() {
        if c == '\\' {
            chars.next();
            continue;
        }
        if let Some(q) = quote {
            if c == q {
                quote = None;
            }
            continue;
        }
        if c == '"' || c == '\'' {
            quote = Some(c);
            continue;
        }
        if c == '/' && chars.peek() == Some(&'*') {
            chars.next();
            let mut closed = false;
            while let Some(c) = chars.next() {
                if c == '*' && chars.peek() == Some(&'/') {
                    chars.next();
                    closed = true;
                    break;
                }
            }
            if !closed {
                return false;
            }
            continue;
        }
        match c {
            '{' | '(' | '[' => {
                stack.push(c);
                if stack.len() > 32 {
                    return false;
                }
            }
            '}' | ')' | ']'
                if stack.pop()
                    != Some(match c {
                        '}' => '{',
                        ')' => '(',
                        _ => '[',
                    }) =>
            {
                return false;
            }
            _ => {}
        }
    }
    stack.is_empty() && quote.is_none()
}

// Resolve only the portable appearance media feature. Keep other CSS intact
// for browser export; the native profile continues to diagnose unsupported rules.
struct AppearanceSheet {
    dark: bool,
    depth: usize,
}
fn raw_css(p: &mut Parser<'_>) -> String {
    let start = p.position();
    while p.next_including_whitespace_and_comments().is_ok() {}
    p.slice_from(start).to_owned()
}
fn resolve_appearance(css: &str, dark: bool, depth: usize) -> Result<String, ()> {
    if depth > 16 {
        return Err(());
    }
    let mut parser = Parser::new(css);
    let mut sheet = AppearanceSheet { dark, depth };
    let mut output = String::new();
    for result in StyleSheetParser::new(&mut parser, &mut sheet) {
        output.push_str(&result.map_err(|_| ())?);
        output.push('\n');
    }
    Ok(output)
}
impl<'i> QualifiedRuleParser<'i> for AppearanceSheet {
    type Prelude = String;
    type QualifiedRule = String;
    type Error = ();
    fn parse_prelude(&mut self, p: &mut Parser<'i>) -> Result<String, ParseError<()>> {
        Ok(raw_css(p))
    }
    fn parse_block(
        &mut self,
        prelude: String,
        _: &ParserState,
        p: &mut Parser<'i>,
    ) -> Result<String, ParseError<()>> {
        Ok(format!("{prelude}{{{}}}", raw_css(p)))
    }
}
impl<'i> AtRuleParser<'i> for AppearanceSheet {
    type Prelude = (String, String);
    type AtRule = String;
    type Error = ();
    fn parse_prelude(
        &mut self,
        name: CowRcStr<'i>,
        p: &mut Parser<'i>,
    ) -> Result<Self::Prelude, ParseError<()>> {
        Ok((name.to_string(), raw_css(p)))
    }
    fn rule_without_block(
        &mut self,
        (name, prelude): Self::Prelude,
        _: &ParserState,
    ) -> Result<String, ()> {
        Ok(format!("@{name} {prelude};"))
    }
    fn parse_block(
        &mut self,
        (name, prelude): Self::Prelude,
        _: &ParserState,
        p: &mut Parser<'i>,
    ) -> Result<String, ParseError<()>> {
        let body = raw_css(p);
        let query: String = prelude
            .chars()
            .filter(|c| !c.is_ascii_whitespace())
            .collect::<String>()
            .to_ascii_lowercase();
        let appearance = match query.as_str() {
            "(prefers-color-scheme:dark)" => Some(true),
            "(prefers-color-scheme:light)" => Some(false),
            _ => None,
        };
        if name.eq_ignore_ascii_case("media")
            && let Some(dark) = appearance
        {
            if dark != self.dark {
                return Ok(String::new());
            }
            return resolve_appearance(&body, self.dark, self.depth + 1)
                .map_err(|()| ParseError::custom(()));
        }
        Ok(format!("@{name} {prelude}{{{body}}}"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn appearance_media_is_cached_separately_and_preserves_cascade_and_browser_css() {
        let css = r":root {--ink:#123456} body {color:var(--ink)}
          @media (prefers-color-scheme: dark) { :root {--ink:#fedcba} }
          @media (prefers-color-scheme: light) { body {background-color:#fff} }
          .browser-only > span { padding:2px }
          @media print { body {color:black} }";
        let light = compile(css);
        let dark = compile_for_scheme(css, true);
        assert_eq!(light.values["body"]["color"], "#123456");
        assert_eq!(dark.values["body"]["color"], "#fedcba");
        assert!(!dark.values["body"].contains_key("background-color"));
        assert!(dark.resolved_css.contains(".browser-only > span"));
        assert!(dark.resolved_css.contains("print"));
        assert!(!dark.resolved_css.contains("prefers-color-scheme"));
        assert!(Arc::ptr_eq(&dark, &compile_for_scheme(css, true)));
        assert!(!Arc::ptr_eq(&dark, &light));
        let nested = format!(
            "{}body {{color:red}}{}",
            "@media (prefers-color-scheme:dark){".repeat(18),
            "}".repeat(18)
        );
        assert!(!compile_for_scheme(&nested, true).is_valid);
    }

    #[test]
    fn all_builtin_appearances_have_readable_text_and_identical_typography() {
        fn luminance(value: &str) -> f64 {
            let hex = theme_values::color(value).unwrap();
            let rgb = u32::from_str_radix(&hex[1..7], 16).unwrap();
            [16, 8, 0]
                .into_iter()
                .zip([0.2126, 0.7152, 0.0722])
                .map(|(shift, weight)| {
                    let c = f64::from((rgb >> shift) & 255) / 255.0;
                    weight
                        * if c <= 0.04045 {
                            c / 12.92
                        } else {
                            ((c + 0.055) / 1.055).powf(2.4)
                        }
                })
                .sum()
        }
        for css in [
            include_str!("../../Themes/github.css"),
            include_str!("../../Themes/whitey.css"),
            include_str!("../../Themes/night.css"),
            include_str!("../../Themes/newsprint.css"),
            include_str!("../../Themes/pixyll.css"),
            include_str!("../../Themes/gothic.css"),
        ] {
            let light = compile(css);
            let dark = compile_for_scheme(css, true);
            assert_ne!(
                light.values["body"]["background-color"],
                dark.values["body"]["background-color"]
            );
            for theme in [&light, &dark] {
                assert!(
                    theme.is_valid && !theme.has_unsupported_rules,
                    "{:?}",
                    theme.diagnostics
                );
                let background = luminance(&theme.values["body"]["background-color"]);
                for element in ["body", "a", "blockquote"] {
                    let text = luminance(&theme.values[element]["color"]);
                    let contrast = (text.max(background) + 0.05) / (text.min(background) + 0.05);
                    assert!(contrast >= 4.5, "{element}: contrast={contrast}");
                }
            }
            assert_eq!(light.fonts, dark.fonts);
            for element in ["body", "h1", "h2", "pre", "code", "th", "td"] {
                assert_eq!(light.lengths.get(element), dark.lengths.get(element));
            }
        }
    }

    #[test]
    fn shared_theme_corpus_compiles_on_every_target() {
        let base = include_str!("../../Themes/Base/default.css");
        for (name, css) in [
            ("github", include_str!("../../Themes/github.css")),
            ("whitey", include_str!("../../Themes/whitey.css")),
            ("night", include_str!("../../Themes/night.css")),
            ("newsprint", include_str!("../../Themes/newsprint.css")),
            ("pixyll", include_str!("../../Themes/pixyll.css")),
            ("gothic", include_str!("../../Themes/gothic.css")),
        ] {
            let snapshot = compile(&format!("{base}\n{css}"));
            assert!(
                snapshot.is_valid && !snapshot.has_unsupported_rules,
                "{name}: {:?}",
                snapshot.diagnostics
            );
            assert_eq!(snapshot.profile_version, 0);
            assert!(snapshot.lengths["h1"].contains_key("font-size"));
            assert!(!snapshot.fonts["body"].is_empty());
            // Sorted maps and an immutable program give deterministic wire output.
            assert_eq!(
                serde_json::to_vec(snapshot.as_ref()).unwrap(),
                serde_json::to_vec(compile(&format!("{base}\n{css}")).as_ref()).unwrap()
            );
        }
    }

    #[test]
    fn declarations_do_not_split_quoted_semicolons_or_comments() {
        let snapshot = compile(
            "body {font-family: \"A;/*B*/\",serif; color: rgb(20,30,40) !important;} body { color: red; } a {color:var(--missing,#abc);} h1 {margin:1em 2em 3em 4em;}",
        );
        assert!(snapshot.is_valid);
        assert_eq!(snapshot.fonts["body"][0], "A;/*B*/");
        assert_eq!(
            snapshot.colors[&snapshot.values["body"]["color"]],
            "#141e28"
        );
        assert_eq!(snapshot.values["h1"]["margin-left"], "4em");
        assert_eq!(snapshot.values["a"]["color"], "#abc");
    }
    #[test]
    fn cascade_variables_quotes_and_recovery() {
        let theme = compile(
            ":root {--ink:#123;--cycle:var(--cycle);} body {color:var(--ink);font-family:\"A;B\",serif;} #write h1 {font-size:2em;margin:1rem 0 .5rem;} a {color:var(--missing,var(--ink));} pre {color:var(--cycle);} @media (max-width:1px) {body {color:red;}}",
        );
        assert!(theme.is_valid && theme.has_unsupported_rules);
        assert_eq!(
            theme.values["body"].get("color"),
            Some(&"#123".to_string()),
            "{theme:?}"
        );
        assert_eq!(theme.values["a"]["color"], "#123");
        assert!(!theme.values["pre"].contains_key("color"));
        assert_eq!(theme.fonts["body"], vec!["A;B", "serif"]);
        assert!((theme.lengths["h1"]["margin-bottom"].value - 0.5).abs() < f64::EPSILON);
        assert!(!compile("body {color:red;").is_valid);
    }
    #[test]
    fn immutable_bounded_cache_and_shipped_selectors() {
        let a = compile(
            "h1+h2 {margin-top:0;} tr:nth-child(even) {color:#123;} ::selection {color:red;}",
        );
        let b = compile(
            "h1+h2 {margin-top:0;} tr:nth-child(even) {color:#123;} ::selection {color:red;}",
        );
        assert!(
            a.is_valid && !a.has_unsupported_rules,
            "{:?}",
            a.diagnostics
        );
        assert!(Arc::ptr_eq(&a, &b));
        assert_eq!(a.values["tr:nth-child(even)"]["color"], "#123");
        assert!(!compile(&" ".repeat(MAX_CSS_BYTES + 1)).is_valid);
    }
}
