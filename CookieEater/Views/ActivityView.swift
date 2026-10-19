import SwiftUI

struct ActivityView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List(model.activity) { entry in
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: entry.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(entry.isError ? .orange : .green)
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.message)
                        .fontWeight(.medium)
                    ForEach(Array(entry.details.enumerated()), id: \.offset) { _, detail in
                        Text(detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text(entry.date, format: .dateTime.month().day().hour().minute())
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
        .overlay {
            if model.activity.isEmpty {
                ContentUnavailableView("No Activity Yet", systemImage: "clock",
                                       description: Text("Cleanups you run and automatic cleanups are listed here."))
            }
        }
        .toolbar {
            Button("Clear Activity", systemImage: "trash") { model.clearActivity() }
                .disabled(model.activity.isEmpty)
        }
        .navigationTitle("Activity")
    }
}
