import BookManagerCore
import SwiftUI

struct MetadataEditorView: View {
    let book: IndexedBook
    let onSave: (BookEdit) -> Void
    let onCancel: () -> Void

    @State private var title = ""
    @State private var authorsText = ""
    @State private var series = ""
    @State private var seriesIndex = ""
    @State private var tagsText = ""
    @State private var rating = 0
    @State private var publisher = ""
    @State private var publicationDate: Date?
    @State private var hasPublicationDate = false
    @State private var languagesText = ""
    @State private var identifiersText = ""
    @State private var comments = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Edit Metadata")
                .font(.headline)
                .padding()
            Form {
                TextField("Title", text: $title)
                TextField("Authors (comma separated)", text: $authorsText)
                TextField("Series", text: $series)
                TextField("Series index", text: $seriesIndex)
                TextField("Tags (comma separated)", text: $tagsText)
                Stepper(value: $rating, in: 0...5) {
                    Text("Rating: \(rating == 0 ? "None" : String(repeating: "★", count: rating))")
                }
                TextField("Publisher", text: $publisher)
                Toggle("Publication date", isOn: $hasPublicationDate)
                if hasPublicationDate {
                    DatePicker("Date", selection: Binding(
                        get: { publicationDate ?? .now },
                        set: { publicationDate = $0 }
                    ), displayedComponents: .date)
                }
                TextField("Languages (comma separated)", text: $languagesText)
                TextField("Identifiers (type=value, one per line)", text: $identifiersText, axis: .vertical)
                TextField("Comments", text: $comments, axis: .vertical)
            }
            .formStyle(.grouped)
            .padding()
            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                Button("Save") {
                    onSave(collectEdit())
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .frame(minWidth: 420, minHeight: 480)
        .onAppear(perform: populate)
    }

    private func populate() {
        title = book.title
        authorsText = book.authors.joined(separator: ", ")
        series = book.series ?? ""
        seriesIndex = book.seriesIndex.map { String($0) } ?? ""
        tagsText = book.tags.joined(separator: ", ")
        rating = book.rating ?? 0
        publisher = book.publisher ?? ""
        if let date = book.publicationDate {
            hasPublicationDate = true
            publicationDate = date
        }
        languagesText = book.languages.joined(separator: ", ")
        identifiersText = book.identifiers.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "\n")
        comments = book.comments ?? ""
    }

    private func collectEdit() -> BookEdit {
        let splitList = { (value: String) -> [String] in
            value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
        var identifiers: [String: String] = [:]
        for line in identifiersText.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            if parts.count == 2 { identifiers[parts[0]] = parts[1] }
        }
        let newSeries = series.trimmingCharacters(in: .whitespacesAndNewlines)
        let seriesEdit: FieldEdit<String> = newSeries.isEmpty ? .clear : .set(newSeries)
        let trimmedIndex = seriesIndex.trimmingCharacters(in: .whitespacesAndNewlines)
        let newIndex = trimmedIndex.isEmpty ? nil : Double(trimmedIndex)
        let indexEdit: FieldEdit<Double> = newSeries.isEmpty ? .clear : (newIndex.map { .set($0) } ?? .clear)
        let ratingEdit: FieldEdit<Int> = rating == 0 ? .clear : .set(rating)
        let publisherEdit: FieldEdit<String> = {
            let value = publisher.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? .clear : .set(value)
        }()
        let dateEdit: FieldEdit<Date> = hasPublicationDate
            ? (publicationDate.map { .set($0) } ?? .clear)
            : .clear
        let commentsEdit: FieldEdit<String> = {
            let value = comments.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? .clear : .set(value)
        }()
        let newTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return BookEdit(
            title: newTitle == book.title ? nil : newTitle,
            authors: splitList(authorsText) == book.authors ? nil : splitList(authorsText),
            series: seriesEdit,
            seriesIndex: indexEdit,
            tags: splitList(tagsText) == book.tags ? nil : splitList(tagsText),
            rating: ratingEdit,
            publisher: publisherEdit,
            publicationDate: dateEdit,
            languages: splitList(languagesText) == book.languages ? nil : splitList(languagesText),
            identifiers: identifiers == book.identifiers ? nil : identifiers,
            comments: commentsEdit
        )
    }
}
