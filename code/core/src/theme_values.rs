//! Portable CSS values. No platform fonts, colors or screen units cross this boundary.
use cssparser::{Parser, Token};
use serde::Serialize;

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Length {
    pub value: f64,
    pub unit: String,
}

pub fn length(raw: &str) -> Option<Length> {
    let mut input = Parser::new(raw);
    let (value, unit) = match input.next().ok()? {
        Token::Number { .. } => (raw.trim().parse::<f64>().ok()?, "px"),
        Token::Percentage { .. } => (
            raw.trim().strip_suffix('%')?.parse::<f64>().ok()? / 100.0,
            "fraction",
        ),
        Token::Dimension { unit, .. } => {
            // Retain source precision: f32 token values can cross a ceil() pixel
            // boundary after font multiplication on native text systems.
            let value = raw
                .trim()
                .get(..raw.trim().len() - unit.len())?
                .parse::<f64>()
                .ok()?;
            let unit = match unit.as_ref() {
                u if u.eq_ignore_ascii_case("px") => "px",
                u if u.eq_ignore_ascii_case("pt") => "pt",
                u if u.eq_ignore_ascii_case("em") => "em",
                u if u.eq_ignore_ascii_case("rem") => "rem",
                _ => return None,
            };
            (value, unit)
        }
        _ => return None,
    };
    if !value.is_finite() || input.expect_exhausted().is_err() {
        return None;
    }
    Some(Length {
        value: if unit == "pt" {
            value * 96.0 / 72.0
        } else {
            value
        },
        unit: if unit == "pt" { "px" } else { unit }.into(),
    })
}

pub fn font_families(raw: &str) -> Vec<String> {
    let mut input = Parser::new(raw);
    input
        .parse_comma_separated(|p| {
            let mut words = Vec::new();
            while !p.is_exhausted() {
                match p.next()? {
                    Token::Ident(word) | Token::QuotedString(word) => words.push(word.to_string()),
                    _ => return Err(cssparser::ParseError::<()>::custom(())),
                }
            }
            if words.is_empty() {
                return Err(cssparser::ParseError::<()>::custom(()));
            }
            Ok(words.join(" "))
        })
        .unwrap_or_default()
}

/// Canonical sRGB hex is used on the wire; platform adapters only instantiate colors.
pub fn color(raw: &str) -> Option<String> {
    let text = raw.trim().to_ascii_lowercase();
    if text == "transparent" {
        return Some("#00000000".into());
    }
    if let Some(hex) = text.strip_prefix('#') {
        let (r, g, b, a) = cssparser::color::parse_hash_color(hex.as_bytes()).ok()?;
        return Some(rgba(
            r,
            g,
            b,
            f64::from(a),
            hex.len() == 4 || hex.len() == 8,
        ));
    }
    if let Ok((r, g, b)) = cssparser::color::parse_named_color(&text) {
        return Some(rgba(r, g, b, 1.0, false));
    }
    let mut input = Parser::new(&text);
    let function = match input.next().ok()? {
        Token::Function(name) => name.to_string(),
        _ => return None,
    };
    if !["rgb", "rgba", "hsl", "hsla"].contains(&function.as_str()) {
        return None;
    }
    let values: Vec<(f64, bool)> = input
        .parse_nested_block(|p| {
            let mut parts = Vec::new();
            while !p.is_exhausted() {
                match p.next()? {
                    Token::Number { value, .. } => parts.push((f64::from(*value), false)),
                    Token::Percentage { unit_value, .. } => {
                        parts.push((f64::from(*unit_value), true));
                    }
                    Token::Comma | Token::Delim('/') => {}
                    _ => return Err(cssparser::ParseError::<()>::custom(())),
                }
            }
            Ok(parts)
        })
        .ok()?;
    if input.expect_exhausted().is_err()
        || !(3..=4).contains(&values.len())
        || values.iter().any(|x| !x.0.is_finite())
    {
        return None;
    }
    let alpha = values.get(3).map_or(1.0, |v| v.0);
    let channels = if function.starts_with("hsl") {
        if !values[1].1 || !values[2].1 {
            return None;
        }
        let hue = values[0].0.rem_euclid(360.0) / 60.0;
        let saturation = values[1].0.clamp(0.0, 1.0);
        let lightness = values[2].0.clamp(0.0, 1.0);
        let chroma = (1.0 - (2.0 * lightness - 1.0).abs()) * saturation;
        let secondary = chroma * (1.0 - (hue % 2.0 - 1.0).abs());
        let offset = lightness - chroma / 2.0;
        let channels = if hue < 1.0 {
            [chroma, secondary, 0.0]
        } else if hue < 2.0 {
            [secondary, chroma, 0.0]
        } else if hue < 3.0 {
            [0.0, chroma, secondary]
        } else if hue < 4.0 {
            [0.0, secondary, chroma]
        } else if hue < 5.0 {
            [secondary, 0.0, chroma]
        } else {
            [chroma, 0.0, secondary]
        };
        channels.map(|value| channel((value + offset) * 255.0))
    } else {
        [values[0], values[1], values[2]]
            .map(|(v, percent)| channel(if percent { v * 255.0 } else { v }))
    };
    Some(rgba(
        channels[0],
        channels[1],
        channels[2],
        alpha,
        values.len() == 4,
    ))
}

#[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
fn channel(value: f64) -> u8 {
    value.clamp(0.0, 255.0).round() as u8
}
fn rgba(r: u8, g: u8, b: u8, a: f64, alpha: bool) -> String {
    if alpha {
        format!("#{r:02x}{g:02x}{b:02x}{:02x}", channel(a * 255.0))
    } else {
        format!("#{r:02x}{g:02x}{b:02x}")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn portable_values() {
        assert_eq!(color("rgba(10,20,30,0.5)"), Some("#0a141e80".into()));
        assert_eq!(color("hsl(120,100%,50%)"), Some("#00ff00".into()));
        assert_eq!(color("rebeccapurple"), Some("#663399".into()));
        assert_eq!(color("#abcd"), Some("#aabbccdd".into()));
        assert!((length("12pt").unwrap().value - 16.0).abs() < f64::EPSILON);
        assert!(length("NaNpx").is_none());
        assert_eq!(
            font_families("\"A,B\", Open Sans, serif"),
            vec!["A,B", "Open Sans", "serif"]
        );
    }
}
