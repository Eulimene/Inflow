//! Platform-independent Markdown byte encoding and line-ending handling.

const UTF8_BOM: &[u8] = &[0xEF, 0xBB, 0xBF];

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum LineEnding {
    Lf,
    CrLf,
}

#[derive(Debug, Eq, PartialEq)]
pub struct DecodedDocument {
    pub text: String,
    pub has_utf8_bom: bool,
    pub line_ending: LineEnding,
}

#[derive(Debug, Eq, PartialEq)]
pub struct OpenedDocument {
    pub text: String,
    pub has_utf8_bom: bool,
    pub line_ending: LineEnding,
    pub requires_line_ending_choice: bool,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DecodeError {
    InvalidUtf8,
    MixedLineEndings,
}

pub fn decode(bytes: &[u8]) -> Result<DecodedDocument, DecodeError> {
    let (content, has_utf8_bom) = bytes
        .strip_prefix(UTF8_BOM)
        .map_or((bytes, false), |content| (content, true));

    let text = std::str::from_utf8(content).map_err(|_| DecodeError::InvalidUtf8)?;
    let line_ending = detect_line_ending(text)?;
    let normalized = match line_ending {
        LineEnding::Lf => text.to_owned(),
        LineEnding::CrLf => text.replace("\r\n", "\n"),
    };

    Ok(DecodedDocument {
        text: normalized,
        has_utf8_bom,
        line_ending,
    })
}

pub fn decode_for_open(bytes: &[u8]) -> Result<OpenedDocument, DecodeError> {
    let (content, has_utf8_bom) = bytes
        .strip_prefix(UTF8_BOM)
        .map_or((bytes, false), |content| (content, true));
    let text = std::str::from_utf8(content).map_err(|_| DecodeError::InvalidUtf8)?;

    let (line_ending, requires_line_ending_choice) = match detect_line_ending(text) {
        Ok(line_ending) => (line_ending, false),
        Err(DecodeError::MixedLineEndings) => (LineEnding::Lf, true),
        Err(error) => return Err(error),
    };

    Ok(OpenedDocument {
        text: normalize_line_endings(text),
        has_utf8_bom,
        line_ending,
        requires_line_ending_choice,
    })
}

pub fn encode(text: &str, has_utf8_bom: bool, line_ending: LineEnding) -> Vec<u8> {
    let mut bytes = Vec::with_capacity(text.len() + usize::from(has_utf8_bom) * UTF8_BOM.len());
    if has_utf8_bom {
        bytes.extend_from_slice(UTF8_BOM);
    }

    match line_ending {
        LineEnding::Lf => bytes.extend_from_slice(text.as_bytes()),
        LineEnding::CrLf => bytes.extend_from_slice(text.replace('\n', "\r\n").as_bytes()),
    }

    bytes
}

fn detect_line_ending(text: &str) -> Result<LineEnding, DecodeError> {
    let bytes = text.as_bytes();
    let mut saw_lf = false;
    let mut saw_crlf = false;
    let mut index = 0;

    while index < bytes.len() {
        match bytes[index] {
            b'\r' if bytes.get(index + 1) == Some(&b'\n') => {
                saw_crlf = true;
                index += 2;
            }
            b'\r' => return Err(DecodeError::MixedLineEndings),
            b'\n' => {
                saw_lf = true;
                index += 1;
            }
            _ => index += 1,
        }
    }

    if saw_lf && saw_crlf {
        Err(DecodeError::MixedLineEndings)
    } else if saw_crlf {
        Ok(LineEnding::CrLf)
    } else {
        Ok(LineEnding::Lf)
    }
}

fn normalize_line_endings(text: &str) -> String {
    let mut normalized = String::with_capacity(text.len());
    let mut characters = text.chars().peekable();
    while let Some(character) = characters.next() {
        if character == '\r' {
            if characters.peek() == Some(&'\n') {
                characters.next();
            }
            normalized.push('\n');
        } else {
            normalized.push(character);
        }
    }
    normalized
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decodes_empty_document_with_lf_default() {
        assert_eq!(
            decode(&[]),
            Ok(DecodedDocument {
                text: String::new(),
                has_utf8_bom: false,
                line_ending: LineEnding::Lf,
            })
        );
    }

    #[test]
    fn round_trips_unicode_lf_document() {
        let original = "# 你好\n\nHello 🌍\n";
        let decoded = decode(original.as_bytes()).expect("valid UTF-8 should decode");

        assert_eq!(decoded.text, original);
        assert_eq!(decoded.line_ending, LineEnding::Lf);
        assert!(!decoded.has_utf8_bom);
        assert_eq!(
            encode(&decoded.text, false, decoded.line_ending),
            original.as_bytes()
        );
    }

    #[test]
    fn preserves_bom_and_crlf_while_normalizing_editor_text() {
        let original = [UTF8_BOM, b"# Title\r\n\r\nBody\r\n"].concat();
        let decoded = decode(&original).expect("valid CRLF document should decode");

        assert_eq!(decoded.text, "# Title\n\nBody\n");
        assert_eq!(decoded.line_ending, LineEnding::CrLf);
        assert!(decoded.has_utf8_bom);
        assert_eq!(
            encode(&decoded.text, decoded.has_utf8_bom, decoded.line_ending),
            original
        );
    }

    #[test]
    fn rejects_invalid_utf8() {
        assert_eq!(decode(&[0xFF, 0xFE]), Err(DecodeError::InvalidUtf8));
    }

    #[test]
    fn rejects_mixed_and_bare_carriage_return_line_endings() {
        assert_eq!(decode(b"one\r\ntwo\n"), Err(DecodeError::MixedLineEndings));
        assert_eq!(decode(b"one\rtwo"), Err(DecodeError::MixedLineEndings));
    }

    #[test]
    fn opens_mixed_line_endings_as_normalized_read_only_content() {
        let source = [UTF8_BOM, "one\r\ntwo\nthree\rfour".as_bytes()].concat();
        let opened = decode_for_open(&source).expect("mixed UTF-8 remains readable");

        assert_eq!(opened.text, "one\ntwo\nthree\nfour");
        assert!(opened.has_utf8_bom);
        assert_eq!(opened.line_ending, LineEnding::Lf);
        assert!(opened.requires_line_ending_choice);
    }

    #[test]
    fn opens_consistent_documents_without_requiring_a_choice() {
        let opened = decode_for_open(b"one\r\ntwo\r\n").expect("CRLF is supported");

        assert_eq!(opened.text, "one\ntwo\n");
        assert_eq!(opened.line_ending, LineEnding::CrLf);
        assert!(!opened.requires_line_ending_choice);
    }
}
