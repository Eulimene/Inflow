//! Literal search over UTF-8 Markdown source.

use std::ops::Range;

use unicode_segmentation::UnicodeSegmentation;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SearchMatch {
    pub source_range: Range<usize>,
}

/// Returns non-overlapping literal matches in source order.
///
/// Case-insensitive matching uses locale-independent Unicode uppercase folding.
/// A match is only accepted when both ends align with original extended
/// grapheme boundaries, so selection never splits a combining sequence or ZWJ
/// emoji. Expanded folds such as `ß` -> `SS` still map to exact source ranges.
pub fn find_literal(source: &str, query: &str, case_sensitive: bool) -> Vec<SearchMatch> {
    if query.is_empty() {
        return Vec::new();
    }

    let grapheme_boundaries = grapheme_boundary_map(source);

    if case_sensitive {
        return valid_matches(source, query, Some, &grapheme_boundaries);
    }

    let (folded_source, source_boundaries) = uppercase_with_source_boundaries(source);
    let folded_query = query
        .chars()
        .flat_map(char::to_uppercase)
        .collect::<String>();

    valid_matches(
        &folded_source,
        &folded_query,
        |offset| source_boundaries.get(offset).copied().flatten(),
        &grapheme_boundaries,
    )
}

fn valid_matches(
    searchable: &str,
    query: &str,
    source_offset: impl Fn(usize) -> Option<usize>,
    grapheme_boundaries: &[bool],
) -> Vec<SearchMatch> {
    let mut matches = Vec::new();
    let mut search_start = 0;

    while search_start <= searchable.len() {
        let Some(relative_start) = searchable[search_start..].find(query) else {
            break;
        };
        let found_start = search_start + relative_start;
        let found_end = found_start + query.len();
        let mapped = source_offset(found_start).zip(source_offset(found_end));

        if let Some((source_start, source_end)) = mapped
            && grapheme_boundaries.get(source_start) == Some(&true)
            && grapheme_boundaries.get(source_end) == Some(&true)
        {
            matches.push(SearchMatch {
                source_range: source_start..source_end,
            });
            search_start = found_end;
            continue;
        }

        let Some(character) = searchable[found_start..].chars().next() else {
            break;
        };
        search_start = found_start + character.len_utf8();
    }

    matches
}

fn grapheme_boundary_map(source: &str) -> Vec<bool> {
    let mut boundaries = vec![false; source.len() + 1];
    for (offset, _) in source.grapheme_indices(true) {
        boundaries[offset] = true;
    }
    boundaries[source.len()] = true;
    boundaries
}

fn uppercase_with_source_boundaries(source: &str) -> (String, Vec<Option<usize>>) {
    let mut folded = String::new();
    let mut boundaries = vec![Some(0)];

    for (source_start, character) in source.char_indices() {
        let source_end = source_start + character.len_utf8();
        folded.extend(character.to_uppercase());
        boundaries.resize(folded.len() + 1, None);
        boundaries[folded.len()] = Some(source_end);
    }

    (folded, boundaries)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ranges(source: &str, query: &str, case_sensitive: bool) -> Vec<Range<usize>> {
        find_literal(source, query, case_sensitive)
            .into_iter()
            .map(|found| found.source_range)
            .collect()
    }

    #[test]
    fn empty_query_has_no_matches() {
        assert!(find_literal("正文", "", false).is_empty());
        assert!(find_literal("", "", true).is_empty());
    }

    #[test]
    fn finds_case_sensitive_unicode_and_multiline_literals() {
        let source = "标题\nAlpha\n标题\nalpha";
        let matches = ranges(source, "标题\nAlpha", true);

        assert_eq!(matches.len(), 1);
        assert_eq!(&source[matches[0].clone()], "标题\nAlpha");
        assert_eq!(ranges(source, "Alpha", true).len(), 1);
        assert_eq!(ranges(source, "alpha", true).len(), 1);
    }

    #[test]
    fn folds_unicode_without_losing_source_byte_ranges() {
        let source = "Straße STRASSE straße";
        let matches = ranges(source, "strasse", false);

        assert_eq!(matches.len(), 3);
        assert_eq!(&source[matches[0].clone()], "Straße");
        assert_eq!(&source[matches[1].clone()], "STRASSE");
        assert_eq!(&source[matches[2].clone()], "straße");
    }

    #[test]
    fn rejects_matches_inside_an_expanded_scalar_fold() {
        assert!(ranges("ß", "s", false).is_empty());
        assert_eq!(ranges("ß", "ss", false), vec![0..2]);
    }

    #[test]
    fn retries_overlapping_folded_candidate_after_invalid_boundary() {
        assert_eq!(ranges("sß", "ss", false), vec![1..3]);
    }

    #[test]
    fn only_returns_complete_extended_grapheme_ranges() {
        let decomposed = "e\u{301}";
        assert!(ranges(decomposed, "e", true).is_empty());
        assert!(ranges(decomposed, "\u{301}", true).is_empty());
        assert_eq!(ranges(decomposed, decomposed, true), vec![0..3]);

        let technologist = "👩‍💻";
        assert!(ranges(technologist, "👩", true).is_empty());
        assert_eq!(
            ranges(technologist, technologist, true),
            vec![0..technologist.len()]
        );
    }

    #[test]
    fn returns_non_overlapping_matches_in_source_order() {
        assert_eq!(ranges("aaaa", "aa", true), vec![0..2, 2..4]);
    }

    #[test]
    fn searches_megabyte_document_with_repeated_terms() {
        let line = "needle 中文 Alpha paragraph\n";
        let repeats = (1_048_576 / line.len()) + 1;
        let source = line.repeat(repeats);

        let matches = find_literal(&source, "needle", false);

        assert!(source.len() > 1_048_576);
        assert!(source.lines().count() > 10_000);
        assert_eq!(matches.len(), repeats);
        assert_eq!(
            &source[matches.last().unwrap().source_range.clone()],
            "needle"
        );
    }
}
