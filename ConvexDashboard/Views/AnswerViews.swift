import Charts
import SwiftUI

/// A query result presented as an answer: a number, a ranked bar chart, a list of cards, or a
/// record, titled with the question. Rows with a document ID open that document.
struct AnswerSections: View {
    let title: String?
    let explanation: String?
    let result: QueryRunResult
    let presentation: AnswerPresentation
    let context: DataContext

    init(title: String?, explanation: String?, display: AnswerDisplay?, result: QueryRunResult, context: DataContext) {
        self.title = display?.title ?? title
        self.explanation = explanation
        self.result = result
        self.context = context
        presentation = AnswerPresentation(value: result.value, display: display)
    }

    var body: some View {
        ConvexSection {
            VStack(alignment: .leading, spacing: 6) {
                if let title {
                    Text(title)
                        .font(.convexDisplay(.headline, weight: .medium))
                        .foregroundStyle(Color.convexText)
                }
                if let explanation {
                    Text(explanation)
                        .font(.footnote)
                        .foregroundStyle(Color.convexSecondaryText)
                }
            }
            .padding(.vertical, 2)

            content
        } header: {
            HStack {
                Eyebrow("Answer")
                Spacer()
                Text(footnote)
                    .font(.convexMono(.caption2))
                    .foregroundStyle(Color.convexSecondaryText)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch presentation {
        case .number(let text, let unit):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(text)
                    .font(.convexDisplay(.largeTitle, weight: .semibold))
                    .foregroundStyle(Color.convexText)
                    .contentTransition(.numericText())
                if let unit {
                    Text(unit)
                        .font(.convexMono(.subheadline))
                        .foregroundStyle(Color.convexSecondaryText)
                }
            }
            .textSelection(.enabled)
        case .text(let text):
            Text(text)
                .font(.body)
                .foregroundStyle(Color.convexText)
                .textSelection(.enabled)
        case .ranking(let rows, let metric, let unit):
            RankingChart(rows: Array(rows.prefix(10)), metric: unit ?? metric)
                .frame(height: CGFloat(min(rows.count, 10)) * 30 + 20)
                .padding(.vertical, 4)
            ForEach(rows) { row in
                rowLink(documentId: row.documentId) {
                    RankRowView(row: row, unit: unit)
                }
            }
        case .list(let rows):
            ForEach(rows) { row in
                rowLink(documentId: row.documentId) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.title)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Color.convexText)
                            .lineLimit(1)
                        Text(row.subtitle)
                            .font(.convexMono(.caption))
                            .foregroundStyle(Color.convexSecondaryText)
                            .lineLimit(2)
                            .opacity(row.subtitle.isEmpty ? 0 : 1)
                    }
                }
            }
        case .record(let fields):
            ForEach(fields, id: \.key) { field in
                LabeledContent {
                    Text(field.value)
                        .font(.convexMono(.subheadline))
                        .foregroundStyle(Color.convexText)
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                } label: {
                    Text(field.key)
                        .font(.convexMono(.caption))
                        .foregroundStyle(Color.convexSecondaryText)
                }
            }
        case .empty:
            Label("No results", systemImage: "tray")
                .foregroundStyle(Color.convexSecondaryText)
        }
    }

    /// Rows with a document ID open the document; others are plain.
    @ViewBuilder
    private func rowLink(documentId: String?, @ViewBuilder label: () -> some View) -> some View {
        if let documentId {
            NavigationLink {
                DocumentLookupView(id: documentId, context: context)
            } label: {
                label()
            }
        } else {
            label()
        }
    }

    private var footnote: String {
        let ms = "\(Int((result.duration * 1000).rounded())) ms"
        switch presentation {
        case .ranking(let rows, _, _): return "\(rows.count) rows · \(ms)"
        case .list(let rows): return "\(rows.count) rows · \(ms)"
        default: return ms
        }
    }
}

struct RankRowView: View {
    let row: AnswerPresentation.RankRow
    let unit: String?

    var body: some View {
        HStack(spacing: 12) {
            Text("\(row.id + 1)")
                .font(.convexMono(.caption, weight: .semibold))
                .foregroundStyle(Color.convexSecondaryText)
                .frame(width: 22, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.label)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.convexText)
                    .lineLimit(1)
                Text(row.detail)
                    .font(.convexMono(.caption2))
                    .foregroundStyle(Color.convexSecondaryText)
                    .lineLimit(1)
                    .opacity(row.detail.isEmpty ? 0 : 1)
            }
            Spacer(minLength: 8)
            Text(unit.map { "\(row.valueText) \($0)" } ?? row.valueText)
                .font(.convexMono(.subheadline, weight: .semibold))
                .foregroundStyle(Color.convexText)
        }
    }
}

/// Horizontal bars for the top rows, labeled with each row's name.
struct RankingChart: View {
    let rows: [AnswerPresentation.RankRow]
    let metric: String

    var body: some View {
        Chart(rows) { row in
            BarMark(x: .value(metric, row.value), y: .value("Name", "\(row.id + 1). \(row.label)"))
                .foregroundStyle(Color.convexAccent.gradient)
                .annotation(position: .trailing, alignment: .leading) {
                    Text(row.valueText)
                        .font(.convexMono(.caption2))
                        .foregroundStyle(Color.convexSecondaryText)
                }
        }
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks { _ in
                AxisValueLabel()
                    .font(.convexMono(.caption2))
            }
        }
        .accessibilityLabel("Ranking of \(rows.count) rows by \(metric)")
    }
}
