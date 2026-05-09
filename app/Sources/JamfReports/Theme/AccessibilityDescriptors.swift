import Charts
import SwiftUI

// MARK: - Trend Line Chart Descriptor

/// Provides VoiceOver data navigation for single-metric line/area trend charts.
/// Pass `dates` and `values` arrays from the chart's data source.
struct TrendLineChartDescriptor: AXChartDescriptorRepresentable {
    let title: String
    let seriesName: String
    let dates: [Date]
    let values: [Double]
    let unit: String

    func makeChartDescriptor() -> AXChartDescriptor {
        let f = SummaryJSONParser.dateFormatter
        let labels = dates.map { f.string(from: $0) }

        let xAxis = AXCategoricalDataAxisDescriptor(
            title: "Snapshot Date",
            categoryOrder: labels
        )
        let minVal = values.min() ?? 0
        let maxVal = values.max() ?? 100
        let yAxis = AXNumericDataAxisDescriptor(
            title: seriesName,
            range: min(minVal * 0.9, 0.0)...max(maxVal * 1.1, 1.0),
            gridlinePositions: []
        ) { "\(String(format: "%.1f", $0))\(self.unit)" }

        let series = AXDataSeriesDescriptor(
            name: seriesName,
            isContinuous: true,
            dataPoints: zip(labels, values).map { AXDataPoint(x: $0, y: $1) }
        )

        return AXChartDescriptor(
            title: title,
            summary: summaryString(labels: labels),
            xAxis: xAxis, yAxis: yAxis, additionalAxes: [], series: [series]
        )
    }

    private func summaryString(labels: [String]) -> String? {
        guard let first = values.first, let last = values.last, labels.count >= 2,
              let firstLabel = labels.first, let lastLabel = labels.last else { return nil }
        let delta = last - first
        let direction = delta > 0 ? "up" : delta < 0 ? "down" : "unchanged"
        return "\(seriesName) \(direction) from \(String(format: "%.1f", first))\(unit) " +
               "to \(String(format: "%.1f", last))\(unit), \(firstLabel) through \(lastLabel)"
    }
}

// MARK: - Multi-Series Line Chart Descriptor

/// For comparison charts showing multiple metrics on the same axes.
struct MultiLineChartDescriptor: AXChartDescriptorRepresentable {
    struct Series {
        let name: String
        let dates: [Date]
        let values: [Double]
    }
    let title: String
    let seriesList: [Series]

    func makeChartDescriptor() -> AXChartDescriptor {
        let f = SummaryJSONParser.dateFormatter
        let allDateStrings = Array(
            Set(seriesList.flatMap { $0.dates }.map { f.string(from: $0) })
        ).sorted()

        let xAxis = AXCategoricalDataAxisDescriptor(
            title: "Snapshot Date",
            categoryOrder: allDateStrings
        )
        let allValues = seriesList.flatMap(\.values)
        let minVal = allValues.min() ?? 0
        let maxVal = allValues.max() ?? 100
        let yAxis = AXNumericDataAxisDescriptor(
            title: "Percentage",
            range: min(minVal * 0.9, 0.0)...max(maxVal * 1.1, 1.0),
            gridlinePositions: []
        ) { "\(String(format: "%.1f", $0))%" }

        let seriesData = seriesList.map { s -> AXDataSeriesDescriptor in
            let sF = SummaryJSONParser.dateFormatter
            return AXDataSeriesDescriptor(
                name: s.name,
                isContinuous: true,
                dataPoints: zip(s.dates, s.values).map { AXDataPoint(x: sF.string(from: $0), y: $1) }
            )
        }

        return AXChartDescriptor(
            title: title,
            summary: nil,
            xAxis: xAxis, yAxis: yAxis, additionalAxes: [], series: seriesData
        )
    }
}

// MARK: - Sector / Donut Chart Descriptor

/// For pie and donut charts — e.g. macOS distribution.
struct SectorChartDescriptor: AXChartDescriptorRepresentable {
    struct Slice {
        let label: String
        let value: Double
    }
    let title: String
    let unit: String
    let slices: [Slice]

    func makeChartDescriptor() -> AXChartDescriptor {
        let xAxis = AXCategoricalDataAxisDescriptor(
            title: "Category",
            categoryOrder: slices.map(\.label)
        )
        let maxVal = slices.map(\.value).max() ?? 1
        let yAxis = AXNumericDataAxisDescriptor(
            title: unit.isEmpty ? "Count" : unit,
            range: 0...max(maxVal * 1.1, 1.0),
            gridlinePositions: []
        ) { "\(String(format: "%.1f", $0))\(self.unit)" }

        let series = AXDataSeriesDescriptor(
            name: title,
            isContinuous: false,
            dataPoints: slices.map { AXDataPoint(x: $0.label, y: $0.value) }
        )
        let summary = slices
            .map { "\($0.label): \(String(format: "%.1f", $0.value))\(unit)" }
            .joined(separator: "; ")

        return AXChartDescriptor(
            title: title,
            summary: summary,
            xAxis: xAxis, yAxis: yAxis, additionalAxes: [], series: [series]
        )
    }
}

// MARK: - Bar Distribution Chart Descriptor

/// For horizontal/vertical bar charts showing counts or percentages per category.
struct BarDistributionChartDescriptor: AXChartDescriptorRepresentable {
    struct Bar {
        let label: String
        let value: Double
    }
    let title: String
    let unit: String
    let bars: [Bar]

    func makeChartDescriptor() -> AXChartDescriptor {
        let xAxis = AXCategoricalDataAxisDescriptor(
            title: "Category",
            categoryOrder: bars.map(\.label)
        )
        let maxVal = bars.map(\.value).max() ?? 1
        let yAxis = AXNumericDataAxisDescriptor(
            title: "Count",
            range: 0...max(maxVal * 1.1, 1.0),
            gridlinePositions: []
        ) { "\(Int($0.rounded()))\(self.unit)" }

        let series = AXDataSeriesDescriptor(
            name: title,
            isContinuous: false,
            dataPoints: bars.map { AXDataPoint(x: $0.label, y: $0.value) }
        )
        let summary = bars
            .map { "\($0.label): \(Int($0.value.rounded()))\(unit)" }
            .joined(separator: "; ")

        return AXChartDescriptor(
            title: title,
            summary: summary,
            xAxis: xAxis, yAxis: yAxis, additionalAxes: [], series: [series]
        )
    }
}

// MARK: - Stacked Bar Chart Descriptor

/// For stacked bar charts — e.g. compliance band distribution over time.
struct StackedBarChartDescriptor: AXChartDescriptorRepresentable {
    struct Band {
        let name: String
        let dateLabels: [String]
        let values: [Int]
    }
    let title: String
    let dateLabels: [String]
    let bands: [Band]

    func makeChartDescriptor() -> AXChartDescriptor {
        let xAxis = AXCategoricalDataAxisDescriptor(
            title: "Snapshot Date",
            categoryOrder: dateLabels
        )
        let allValues = bands.flatMap(\.values).map(Double.init)
        let maxVal = allValues.max() ?? 1
        let yAxis = AXNumericDataAxisDescriptor(
            title: "Device Count",
            range: 0...max(maxVal * 1.1, 1.0),
            gridlinePositions: []
        ) { "\(Int($0.rounded())) devices" }

        let seriesData = bands.map { band in
            AXDataSeriesDescriptor(
                name: band.name,
                isContinuous: false,
                dataPoints: zip(band.dateLabels, band.values).map {
                    AXDataPoint(x: $0, y: Double($1))
                }
            )
        }

        return AXChartDescriptor(
            title: title,
            summary: nil,
            xAxis: xAxis, yAxis: yAxis, additionalAxes: [], series: seriesData
        )
    }
}
