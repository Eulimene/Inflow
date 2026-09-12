//! Owned parser output shared by every derived Markdown view.

use std::ops::Range;

use pulldown_cmark::{Event, Options, Parser};

/// One parser event paired with its exact end-exclusive UTF-8 source range.
#[derive(Clone, Debug, PartialEq)]
pub struct LocatedEvent {
    pub event: Event<'static>,
    pub source_range: Range<usize>,
}

/// An owned, revision-local Markdown intermediate representation.
///
/// `pulldown-cmark` normally borrows the source. Converting its events to owned
/// values lets the engine parse once and safely share the result between
/// analysis, highlighting, references and rendering without retaining a
/// self-referential parser.
#[derive(Clone, Debug, PartialEq)]
pub struct DocumentIr {
    source: String,
    events: Vec<LocatedEvent>,
}

impl DocumentIr {
    pub fn parse(source: &str, options: Options) -> Self {
        let events = Parser::new_ext(source, options)
            .into_offset_iter()
            .map(|(event, source_range)| {
                debug_assert!(source.get(source_range.clone()).is_some());
                LocatedEvent {
                    event: event.into_static(),
                    source_range,
                }
            })
            .collect();
        Self {
            source: source.to_owned(),
            events,
        }
    }

    pub fn source(&self) -> &str {
        &self.source
    }

    pub fn events(&self) -> &[LocatedEvent] {
        &self.events
    }
}

pub fn dialect_options(math_enabled: bool) -> Options {
    let mut options = Options::empty();
    options.insert(Options::ENABLE_TABLES);
    options.insert(Options::ENABLE_FOOTNOTES);
    if math_enabled {
        options.insert(Options::ENABLE_MATH);
    }
    options.insert(Options::ENABLE_STRIKETHROUGH);
    options.insert(Options::ENABLE_TASKLISTS);
    options
}

#[cfg(test)]
mod tests {
    use pulldown_cmark::{Event, Tag};

    use super::*;

    #[test]
    fn owns_unicode_events_and_preserves_exact_source_ranges() {
        let document = {
            let source = String::from("# 标题\n\n正文 **加粗**");
            DocumentIr::parse(&source, dialect_options(true))
        };

        assert_eq!(document.source(), "# 标题\n\n正文 **加粗**");
        assert!(document.events().iter().all(|located| {
            document
                .source()
                .get(located.source_range.clone())
                .is_some()
        }));
        assert!(document.events().iter().any(|located| {
            matches!(located.event, Event::Start(Tag::Heading { .. }))
                && &document.source()[located.source_range.clone()] == "# 标题\n"
        }));
        assert!(
            document.events().iter().any(
                |located| matches!(&located.event, Event::Text(text) if text.as_ref() == "加粗")
            )
        );
    }
}
