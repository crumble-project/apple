import apfelkern
import SwiftUI

/// A visual a bot showed inline with its `show` tool: headline numbers, a table, or a chart.
struct DisplayView: View {
    let component: DisplayComponent

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
            }
            content
                .padding(14)
                .background(.background, in: .rect(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.separator))
        }
        .frame(maxWidth: Palette.column - 96, alignment: .leading)
    }

    private var title: String? {
        switch component {
        case .stats(let title, _), .table(let title, _, _): title
        case .chart(let chart): chart.title
        }
    }

    @ViewBuilder private var content: some View {
        switch component {
        case .stats(_, let items):
            StatsView(items: items)
        case .table(_, let columns, let rows):
            DisplayTable(columns: columns, rows: rows.map { $0.map(\.text) }, numeric: numericColumns(rows))
        case .chart(let chart):
            // The card hugs the widest layout the server compiled instead of stretching past it.
            ChartView(chart: chart).frame(maxWidth: chart.layouts.map(\.width).max().map { CGFloat($0) })
        }
    }

    private func numericColumns(_ rows: [[DisplayComponent.Cell]]) -> Set<Int> {
        let width = rows.map(\.count).max() ?? 0
        return Set((0..<width).filter { column in
            rows.allSatisfy { row in
                guard column < row.count, case .number = row[column] else { return false }
                return true
            }
        })
    }
}

private struct StatsView: View {
    let items: [DisplayComponent.Stat]

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 120), alignment: .topLeading)], alignment: .leading, spacing: 14
        ) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.label).font(.caption).foregroundStyle(.secondary)
                    Text(item.value)
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    if let change = item.change {
                        Label(change, systemImage: symbol(item.trend))
                            .font(.caption.weight(.medium))
                            .monospacedDigit()
                            .foregroundStyle(color(item.trend))
                    }
                    if let caption = item.caption {
                        Text(caption).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func symbol(_ trend: DisplayComponent.Trend?) -> String {
        switch trend {
        case .rising: "arrow.up.right"
        case .falling: "arrow.down.right"
        case .flat, nil: "arrow.right"
        }
    }

    private func color(_ trend: DisplayComponent.Trend?) -> Color {
        switch trend {
        case .rising: .green
        case .falling: .red
        case .flat, nil: .secondary
        }
    }
}

/// Columns of text, inline Markdown when it came from a reply; numeric columns align trailing so digits line up.
struct DisplayTable: View {
    let columns: [String]
    let rows: [[String]]
    var numeric: Set<Int> = []
    var markdown = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    ForEach(Array(columns.enumerated()), id: \.offset) { index, column in
                        Text(cell(column))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .gridColumnAlignment(numeric.contains(index) ? .trailing : .leading)
                    }
                }
                Divider()
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(columns.indices, id: \.self) { index in
                            Text(cell(index < row.count ? row[index] : "")).monospacedDigit()
                        }
                    }
                }
            }
            .textSelection(.enabled)
        }
    }

    private func cell(_ text: String) -> AttributedString {
        markdown ? inlineMarkdown(text) : AttributedString(text)
    }
}
