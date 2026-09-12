use crate::engine::{Selection, TextPatch};

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct HistoryEntry {
    pub(crate) forward: TextPatch,
    pub(crate) inverse: TextPatch,
    pub(crate) selection_before: Selection,
    pub(crate) selection_after: Selection,
    pub(crate) group_id: Option<String>,
}

#[derive(Default)]
pub(crate) struct History {
    undo: Vec<HistoryEntry>,
    redo: Vec<HistoryEntry>,
}

impl History {
    pub(crate) fn record(&mut self, entry: HistoryEntry) {
        if !self
            .undo
            .last_mut()
            .is_some_and(|previous| merge_entries(previous, &entry))
        {
            self.undo.push(entry);
        }
        self.redo.clear();
    }

    pub(crate) fn take_undo(&mut self) -> Option<HistoryEntry> {
        self.undo.pop()
    }

    pub(crate) fn take_redo(&mut self) -> Option<HistoryEntry> {
        self.redo.pop()
    }

    pub(crate) fn complete_undo(&mut self, entry: HistoryEntry) {
        self.redo.push(entry);
    }

    pub(crate) fn complete_redo(&mut self, entry: HistoryEntry) {
        self.undo.push(entry);
    }

    pub(crate) fn clear(&mut self) {
        self.undo.clear();
        self.redo.clear();
    }

    pub(crate) fn can_undo(&self) -> bool {
        !self.undo.is_empty()
    }

    pub(crate) fn can_redo(&self) -> bool {
        !self.redo.is_empty()
    }
}

fn merge_entries(previous: &mut HistoryEntry, next: &HistoryEntry) -> bool {
    let Some(group_id) = previous.group_id.as_deref() else {
        return false;
    };
    if next.group_id.as_deref() != Some(group_id) {
        return false;
    }

    let previous_is_insertion = previous.forward.range.start == previous.forward.range.end
        && !previous.forward.inserted.is_empty()
        && previous.inverse.inserted.is_empty();
    let next_is_insertion = next.forward.range.start == next.forward.range.end
        && !next.forward.inserted.is_empty()
        && next.inverse.inserted.is_empty();
    if previous_is_insertion
        && next_is_insertion
        && next.forward.range.start
            == previous.forward.range.start + previous.forward.inserted.len()
    {
        previous.forward.inserted.push_str(&next.forward.inserted);
        previous.inverse.range.end += next.forward.inserted.len();
        previous.selection_after = next.selection_after.clone();
        return true;
    }

    let previous_is_deletion = previous.forward.inserted.is_empty()
        && previous.inverse.range.start == previous.inverse.range.end
        && !previous.inverse.inserted.is_empty();
    let next_is_deletion = next.forward.inserted.is_empty()
        && next.inverse.range.start == next.inverse.range.end
        && !next.inverse.inserted.is_empty();
    if !previous_is_deletion || !next_is_deletion {
        return false;
    }

    if next.forward.range.end == previous.forward.range.start {
        previous.forward.range.start = next.forward.range.start;
        previous.inverse.range.start = next.inverse.range.start;
        previous.inverse.range.end = next.inverse.range.end;
        previous.inverse.inserted =
            format!("{}{}", next.inverse.inserted, previous.inverse.inserted);
        previous.selection_after = next.selection_after.clone();
        return true;
    }

    if next.forward.range.start == previous.forward.range.start {
        previous.forward.range.end += next.inverse.inserted.len();
        previous.inverse.inserted.push_str(&next.inverse.inserted);
        previous.selection_after = next.selection_after.clone();
        return true;
    }

    false
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::engine::ByteRange;

    fn entry(forward: TextPatch, inverse: TextPatch, group_id: Option<&str>) -> HistoryEntry {
        HistoryEntry {
            forward,
            inverse,
            selection_before: Selection { start: 0, end: 0 },
            selection_after: Selection { start: 0, end: 0 },
            group_id: group_id.map(str::to_owned),
        }
    }

    #[test]
    fn grouped_adjacent_insertions_form_one_memento() {
        let mut history = History::default();
        history.record(entry(
            TextPatch {
                range: ByteRange { start: 0, end: 0 },
                inserted: "a".to_owned(),
            },
            TextPatch {
                range: ByteRange { start: 0, end: 1 },
                inserted: String::new(),
            },
            Some("typing"),
        ));
        history.record(entry(
            TextPatch {
                range: ByteRange { start: 1, end: 1 },
                inserted: "b".to_owned(),
            },
            TextPatch {
                range: ByteRange { start: 1, end: 2 },
                inserted: String::new(),
            },
            Some("typing"),
        ));

        let merged = history.take_undo().expect("merged history entry");
        assert_eq!(merged.forward.inserted, "ab");
        assert_eq!(merged.inverse.range, ByteRange { start: 0, end: 2 });
        assert!(!history.can_undo());
    }

    #[test]
    fn recording_after_undo_clears_redo_branch() {
        let mut history = History::default();
        let original = entry(
            TextPatch {
                range: ByteRange { start: 0, end: 0 },
                inserted: "a".to_owned(),
            },
            TextPatch {
                range: ByteRange { start: 0, end: 1 },
                inserted: String::new(),
            },
            None,
        );
        history.record(original);
        let undone = history.take_undo().expect("undo entry");
        history.complete_undo(undone);
        assert!(history.can_redo());

        history.record(entry(
            TextPatch {
                range: ByteRange { start: 0, end: 0 },
                inserted: "b".to_owned(),
            },
            TextPatch {
                range: ByteRange { start: 0, end: 1 },
                inserted: String::new(),
            },
            None,
        ));
        assert!(!history.can_redo());
    }
}
