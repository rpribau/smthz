import SwiftUI

/// Present inside a full-window ZStack. UI-29 owns the Cmd-J binding and action dispatch.
struct SmthzJumpPalette: View {
    @Bindable var model: SmthzJumpPaletteModel
    let onAction: (SmthzJumpPaletteModel.Action) -> Void
    let onDismiss: () -> Void
    @State private var showFilters = false
    @State private var filterSearch = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        SmthzPaletteSurface(title: "Jump to...", onDismiss: onDismiss) {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    SmthzIcon.image(.search).frame(width: 16, height: 16).opacity(0.6)
                    TextField("Search chats, terminals, workspaces, tasks, settings, and actions...", text: $model.query)
                        .textFieldStyle(.plain).font(SmthzFont.ui(size: 14))
                        .focused($searchFocused)
                        .onSubmit(openSelection)
                        .onKeyPress(.tab) { showFilters = true; return .handled }
                    Button { showFilters.toggle() } label: {
                        SmthzIcon.image("list-filter").frame(width: 16, height: 16)
                    }
                    .buttonStyle(SmthzButtonStyle(.ghost, size: .iconXS))
                    .accessibilityLabel("Filter results")
                    .popover(isPresented: $showFilters) { filterMenu }
                }
                .padding(.horizontal, 14).frame(height: 48)
                .background(SmthzTheme.muted.opacity(0.28), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SmthzTheme.border.opacity(0.55)))
                .padding(12)
                if model.hostFilter != nil || model.projectFilter != nil {
                    HStack(spacing: 6) {
                        Text("Scoped to").foregroundStyle(SmthzTheme.mutedForeground)
                        if let host = model.hostFilter { chip(host) { model.hostFilter = nil } }
                        if let project = model.projectFilter { chip(project) { model.projectFilter = nil } }
                        Button("Clear all") { model.clearFilters() }.buttonStyle(.plain)
                        Spacer()
                    }.font(SmthzFont.ui(size: 11)).padding(.horizontal, 14).padding(.bottom, 8)
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 3) {
                            if model.isLoading && model.filtered.isEmpty {
                                SmthzPaletteState(title: "Loading jump targets", subtitle: "Gathering your recent worktrees and open tabs.", loading: true)
                            } else if model.filtered.isEmpty {
                                SmthzPaletteState(
                                    title: model.query.isEmpty ? "No active worktrees, settings, actions, or open tabs" : "No results match your search",
                                    subtitle: model.query.isEmpty ? "Create a worktree or open a tab in smthz to get started." : "Try a worktree, setting, action, tab title, agent prompt, URL, PR, or port.")
                            } else {
                                ForEach(SmthzJumpPaletteModel.Section.allCases) { section in
                                    let rows = model.filtered.filter { $0.section == section }
                                    if !rows.isEmpty {
                                        Text(section.rawValue).font(SmthzFont.ui(size: 11, weight: .semibold))
                                            .foregroundStyle(SmthzTheme.mutedForeground)
                                            .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 4)
                                        ForEach(rows) { row in
                                            SmthzPaletteRow(title: row.title, subtitle: row.subtitle, icon: row.icon,
                                                            badge: row.badge, selected: model.selection?.id == row.id) {
                                                onDismiss(); onAction(row.action)
                                            }
                                            .id(row.id)
                                            .onHover { if $0 { model.selectedID = row.id } }
                                        }
                                    }
                                }
                            }
                        }.padding(.horizontal, 10).padding(.bottom, 10)
                    }
                    .frame(maxHeight: 480)
                    .onChange(of: model.selectedID) { _, value in
                        if let value { proxy.scrollTo(value, anchor: .center) }
                    }
                }
                SmthzPaletteFooter(showsFilter: true)
            }
        }
        .onAppear { searchFocused = true; model.resetSelection() }
        .onChange(of: model.query) { model.resetSelection() }
        .onChange(of: model.hostFilter) { model.resetSelection() }
        .onChange(of: model.projectFilter) { model.resetSelection() }
        .onMoveCommand { direction in
            if direction == .down { model.move(1) }
            if direction == .up { model.move(-1) }
        }
    }

    private func openSelection() {
        guard let target = model.selection else { return }
        onDismiss(); onAction(target.action)
    }

    private func chip(_ title: String, remove: @escaping () -> Void) -> some View {
        Button(action: remove) {
            HStack(spacing: 4) { Text(title); SmthzIcon.image(.x).frame(width: 10, height: 10) }
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(SmthzTheme.secondary, in: Capsule())
        }.buttonStyle(.plain).accessibilityLabel("Remove \(title) filter")
    }

    private var filterMenu: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Filter results").font(SmthzFont.ui(size: 12, weight: .semibold))
            TextField("Search hosts and projects...", text: $filterSearch).textFieldStyle(.roundedBorder)
            Text("Hosts").foregroundStyle(SmthzTheme.mutedForeground)
            ForEach(model.hosts.filter { filterSearch.isEmpty || $0.localizedCaseInsensitiveContains(filterSearch) }, id: \.self) { host in
                Button { model.hostFilter = model.hostFilter == host ? nil : host } label: {
                    HStack { Text(host); Spacer(); if model.hostFilter == host { Image(systemName: "checkmark") } }
                }.buttonStyle(.plain)
            }
            Text("Projects").foregroundStyle(SmthzTheme.mutedForeground)
            if model.projects.isEmpty { Text("No projects").foregroundStyle(SmthzTheme.mutedForeground) }
            ForEach(model.projects.filter { filterSearch.isEmpty || $0.localizedCaseInsensitiveContains(filterSearch) }, id: \.self) { project in
                Button(project) { model.projectFilter = model.projectFilter == project ? nil : project }.buttonStyle(.plain)
            }
            Divider()
            Button("Clear all") { model.clearFilters() }.buttonStyle(.plain)
            Button("Done") { showFilters = false; searchFocused = true }.buttonStyle(.plain)
        }.font(SmthzFont.ui(size: 12)).padding(12).frame(width: 250)
    }
}

/// Shared visual shell for both palettes; callers control presentation and restore prior focus.
struct SmthzPaletteSurface<Content: View>: View {
    let title: String
    let onDismiss: () -> Void
    @ViewBuilder let content: () -> Content
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.55).ignoresSafeArea().onTapGesture(perform: onDismiss)
                    .accessibilityHidden(true)
                content()
                    .frame(width: min(900, max(0, geometry.size.width - 32)))
                    .background {
                        RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial)
                            .overlay(RoundedRectangle(cornerRadius: 12).fill(SmthzTheme.background.opacity(reduceTransparency ? 1 : 0.96)))
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(SmthzTheme.border.opacity(0.7)))
                    .shadow(color: .black.opacity(0.32), radius: 42, y: 26)
                    .accessibilityElement(children: .contain).accessibilityLabel(title)
                    .accessibilityAddTraits(.isModal)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .font(SmthzFont.ui(size: 12)).foregroundStyle(SmthzTheme.foreground)
            .onExitCommand(perform: onDismiss)
        }
    }
}

struct SmthzPaletteRow: View {
    let title: String
    var subtitle = ""
    var icon: SmthzIcon.Name = "file-text"
    var badge: String? = nil
    let selected: Bool
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                SmthzIcon.image(icon).resizable().scaledToFit().frame(width: 16, height: 16)
                    .foregroundStyle(SmthzTheme.mutedForeground)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(SmthzFont.ui(size: 13, weight: .medium)).lineLimit(1)
                    if !subtitle.isEmpty {
                        Text(subtitle).font(SmthzFont.ui(size: 11)).foregroundStyle(SmthzTheme.mutedForeground).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if let badge {
                    Text(badge).font(SmthzFont.ui(size: 10)).foregroundStyle(SmthzTheme.mutedForeground)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(SmthzTheme.muted.opacity(0.5), in: RoundedRectangle(cornerRadius: 4))
                }
            }.padding(.horizontal, 10).padding(.vertical, 9).frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(RoundedRectangle(cornerRadius: 8))
                .background(selected ? (colorScheme == .dark ? SmthzTheme.accent : SmthzTheme.foreground.opacity(0.13)) : .clear,
                            in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SmthzTheme.foreground.opacity(selected ? (colorScheme == .dark ? 0.16 : 0.19) : 0)))
        }.buttonStyle(.plain)
            .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

struct SmthzPaletteState: View {
    let title: String
    var subtitle = ""
    var loading = false
    var body: some View {
        VStack(spacing: 8) {
            if loading { ProgressView().controlSize(.small) }
            Text(title).font(SmthzFont.ui(size: 14, weight: .medium))
            if !subtitle.isEmpty { Text(subtitle).font(SmthzFont.ui(size: 12)).foregroundStyle(SmthzTheme.mutedForeground) }
        }.multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(.horizontal, 24).padding(.vertical, 40)
    }
}

struct SmthzPaletteFooter: View {
    var showsFilter = false
    var body: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            KeyCapView("Enter"); Text("Open")
            KeyCapView("Esc"); Text("Close")
            KeyCapView("↑↓"); Text("Move")
            if showsFilter { KeyCapView("Tab"); Text("Filter") }
        }.font(SmthzFont.ui(size: 11)).foregroundStyle(SmthzTheme.mutedForeground)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .overlay(alignment: .top) { SmthzTheme.border.opacity(0.6).frame(height: 1) }
    }
}

#Preview("Jump palette") {
    SmthzJumpPalette(model: SmthzJumpPaletteModel(), onAction: { _ in }, onDismiss: {})
        .frame(width: 1100, height: 800)
}
