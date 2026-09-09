import SwiftUI

struct ContentView: View {
    @Bindable var model: HarnessModel

    var body: some View {
        NavigationStack {
            List {
                Section("Session") {
                    LabeledContent("State", value: model.state)
                    LabeledContent("Progress", value: model.progress.formatted(.percent.precision(.fractionLength(1))))
                    LabeledContent("Rate", value: ByteCountFormatter.string(fromByteCount: Int64(model.downloadRate), countStyle: .file) + "/s")
                    LabeledContent("Checkpoint", value: model.checkpointState)
                    if let error = model.error { Text(error).foregroundStyle(.red) }
                }
                Section("Metadata") {
                    Text(model.name.isEmpty ? "Not loaded" : model.name)
                    LabeledContent("Selected", value: model.selectedFileDescription)
                    ForEach(model.files, id: \.index) { file in
                        VStack(alignment: .leading) {
                            Text(file.path)
                            Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)).font(.caption)
                        }
                    }
                }
                Section("Streaming window") {
                    LabeledContent("Pieces", value: model.windowDescription)
                    LabeledContent("Deadlines", value: model.deadlineDescription)
                }
                Section("Controls") {
                    Button("Load legal Sintel fixture") { Task { await model.loadFixture() } }
                    Button("Start selected file") { Task { await model.start() } }
                    Button("Pause") { Task { await model.pause() } }
                    Button("Checkpoint") { Task { await model.checkpointForBackground() } }
                    Button("Destroy and restore") { Task { await model.destroyAndRestore() } }
                    Button("Move window forward") { Task { await model.moveWindow() } }
                    Button("Remove without deleting") { Task { await model.remove() } }
                }
            }
            .navigationTitle("Libtorrent Harness")
        }
    }
}
