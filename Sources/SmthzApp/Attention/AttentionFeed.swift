import SwiftUI

// shortcut: no dedicated Activity page exists; embed this feed when that page is introduced.
struct AttentionFeed: View {
    private var model: AttentionModel { .shared }
    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("Activity").font(.headline)
                Spacer()
                Button("Mark All as Read") { model.markAllRead() }
            }
            if let error = model.lastError { Text(error).foregroundStyle(.red) }
            List(model.items) { item in
                HStack {
                    Button { model.open(item) } label: {
                        VStack(alignment: .leading) {
                            Text(item.title).fontWeight(item.unread ? .semibold : .regular)
                            Text(item.workspaceName).font(.caption)
                            Text(item.body).lineLimit(3)
                        }
                    }.buttonStyle(.plain)
                    Spacer()
                    if item.unread { Button("Mark as Read") { model.markRead(item.id) } }
                }
            }
            if model.items.isEmpty { Text("No agent activity yet.").foregroundStyle(.secondary) }
        }.padding()
    }
}
