import NexusCore
import SwiftUI

/// Widget gallery: live previews with Add, plus the list of active widget instances.
struct WidgetsGalleryView: View {
    @EnvironmentObject private var widgets: WidgetManager
    @EnvironmentObject private var monitor: SystemMonitor
    @State private var search = ""

    private let grid = [GridItem(.adaptive(minimum: 220), spacing: 14)]

    private var kinds: [WidgetKind] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return WidgetKind.allCases.filter { q.isEmpty || $0.title.lowercased().contains(q) || $0.summary.lowercased().contains(q) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(Theme.secondary)
                        TextField("Search widgets", text: $search).textFieldStyle(.plain)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .glassCard(cornerRadius: 10)
                    .frame(maxWidth: 300)
                    Spacer()
                    Button(widgets.anyVisible ? "Hide All" : "Show All") { widgets.showAll(!widgets.anyVisible) }
                        .disabled(widgets.widgets.isEmpty)
                }

                SectionLabel(text: "Gallery")
                LazyVGrid(columns: grid, spacing: 14) {
                    ForEach(kinds) { kind in GalleryCard(kind: kind) }
                }

                SectionLabel(text: "On your desktop (\(widgets.widgets.count))")
                if widgets.widgets.isEmpty {
                    Text("Add a widget above. It appears on your desktop: drag to move, drag an edge to resize, hover for options.")
                        .font(.system(size: 12)).foregroundStyle(Theme.tertiary)
                } else {
                    VStack(spacing: 0) {
                        ForEach(widgets.widgets) { w in
                            ActiveWidgetRow(widget: w)
                            if w.id != widgets.widgets.last?.id { Rectangle().fill(Theme.hairline).frame(height: 1) }
                        }
                    }
                    .glassCard()
                }
            }
            .padding(28)
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("Widgets")
        .onAppear { monitor.subscribe() }
        .onDisappear { monitor.unsubscribe() }
    }
}

private struct GalleryCard: View {
    @EnvironmentObject private var widgets: WidgetManager
    let kind: WidgetKind
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Live preview using the real widget content.
            WidgetContent(widget: WidgetInstance(kind: kind, frame: CGRect(origin: .zero, size: kind.defaultSize)))
                .padding(14)
                .frame(height: 120, alignment: .topLeading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .softFill(Theme.fill, cornerRadius: 12)
                .allowsHitTesting(false)
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(kind.title).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.primary)
                    Text(kind.summary).font(.system(size: 11)).foregroundStyle(Theme.tertiary).lineLimit(2)
                }
                Spacer()
                Button { widgets.add(kind) } label: { Label("Add", systemImage: "plus") }
                    .help("Place a \(kind.title) widget on your desktop")
            }
        }
        .padding(14)
        .glassCard()
        .scaleEffect(hovering ? 1.01 : 1)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

private struct ActiveWidgetRow: View {
    @EnvironmentObject private var widgets: WidgetManager
    let widget: WidgetInstance

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: widget.kind.symbolName).frame(width: 20).foregroundStyle(Theme.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(widget.kind.title).font(.system(size: 13)).foregroundStyle(Theme.primary)
                Text("\(Int(widget.width))×\(Int(widget.height))\(widget.alwaysOnTop ? " · always on top" : "")")
                    .font(.system(size: 10)).foregroundStyle(Theme.tertiary)
            }
            Spacer()
            Toggle("On top", isOn: Binding(get: { widget.alwaysOnTop }, set: { widgets.setAlwaysOnTop(widget.id, $0) }))
                .toggleStyle(.checkbox)
            Toggle("", isOn: Binding(get: { widget.isVisible }, set: { widgets.setVisible(widget.id, $0) }))
                .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                .help(widget.isVisible ? "Hide" : "Show")
            GlassIconButton(systemImage: "plus.square.on.square", help: "Duplicate") { widgets.duplicate(widget.id) }
            GlassIconButton(systemImage: "trash", help: "Remove") { widgets.remove(widget.id) }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }
}
