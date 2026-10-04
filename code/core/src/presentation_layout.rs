//! Layout policy over host measurements, expressed in logical pixels.
use serde::{Deserialize, Serialize};

#[derive(Debug, Deserialize)]
pub struct TableMeasurements {
    pub columns: Vec<f64>,
    pub available_width: f64,
    pub horizontal_padding: f64,
}
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct TableLayout {
    pub widths: Vec<f64>,
}

pub fn table(input: &TableMeasurements) -> TableLayout {
    if input.columns.is_empty()
        || input.columns.len() > 100
        || !input.available_width.is_finite()
        || !input.horizontal_padding.is_finite()
        || input.columns.iter().any(|v| !v.is_finite() || *v < 0.0)
    {
        return TableLayout { widths: Vec::new() };
    }
    let widths: Vec<f64> = input
        .columns
        .iter()
        .map(|width| {
            (width + input.horizontal_padding.max(0.0))
                .ceil()
                .clamp(72.0, 360.0)
        })
        .collect();
    let target = input.available_width.max(1.0);
    let total: f64 = widths.iter().sum();
    let count = f64::from(u32::try_from(widths.len()).unwrap_or(100));
    let widths = if total < target {
        widths.iter().map(|w| (w / total) * target).collect()
    } else if total > target {
        let minimum = 56.0_f64.min(target / count);
        let flexible: Vec<f64> = widths.iter().map(|w| (w - minimum).max(0.0)).collect();
        let sum: f64 = flexible.iter().sum();
        let remaining = (target - minimum * count).max(0.0);
        if sum > 0.0 {
            flexible
                .iter()
                .map(|w| minimum + remaining * (w / sum))
                .collect()
        } else {
            vec![target / count; widths.len()]
        }
    } else {
        widths
    };
    TableLayout { widths }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn widths_fill_without_overflow_on_every_host() {
        for available_width in [1.0, 100.0, 800.0, 2000.0] {
            let layout = table(&TableMeasurements {
                columns: vec![0.0, 32.0, 780.0],
                available_width,
                horizontal_padding: 24.0,
            });
            assert!((layout.widths.iter().sum::<f64>() - available_width).abs() < 0.000_001);
            assert!(layout.widths.iter().all(|w| *w > 0.0));
        }
        assert!(
            table(&TableMeasurements {
                columns: vec![f64::NAN],
                available_width: 800.0,
                horizontal_padding: 24.0
            })
            .widths
            .is_empty()
        );
    }
}
