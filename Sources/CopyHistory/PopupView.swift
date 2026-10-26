import SwiftUI
import CopyHistoryCore

struct PopupView: View {
  @ObservedObject var vm: PopupViewModel
  @ObservedObject var settings: AppSettings
  @FocusState private var searchFocused: Bool

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
        TextField("Search clipboard history", text: $vm.query)
          .textFieldStyle(.plain)
          .font(.title3)
          .focused($searchFocused)
      }
      .padding(12)
      Divider()
      switch vm.mode {
      case .list: list
      case .transforms: picker
      }
      Divider()
      footer
    }
    .frame(width: 560, height: 420)
    .background(.regularMaterial)
    .clipShape(RoundedRectangle(cornerRadius: 14))
    .onAppear { searchFocused = true }
    .onChange(of: vm.focusTick) { _, _ in searchFocused = true }
  }

  private var list: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(spacing: 2) {
          if vm.items.isEmpty {
            Text(vm.query.isEmpty ? "Nothing copied yet" : "No matches")
              .foregroundStyle(.secondary).padding(.top, 40)
          }
          ForEach(Array(vm.items.enumerated()), id: \.element.id) { index, entry in
            EntryRow(entry: entry, text: vm.displayText(for: entry), ocrSnippet: vm.ocrSnippet(for: entry),
                     index: index, selected: index == vm.selection)
              .id(entry.id)
              .contentShape(Rectangle())
              .onTapGesture {
                vm.pasteItem(at: index, flipPlain: NSEvent.modifierFlags.contains(.option))
              }
          }
        }
        .padding(6)
      }
      .onChange(of: vm.selection) { _, new in
        if vm.items.indices.contains(new) { proxy.scrollTo(vm.items[new].id) }
      }
    }
  }

  private var picker: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text("Transform and paste").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.top, 8)
      if vm.transforms.isEmpty {
        Text("No transforms apply to this text").foregroundStyle(.secondary).padding(12)
      }
      ScrollView {
        VStack(spacing: 2) {
          ForEach(Array(vm.transforms.enumerated()), id: \.offset) { index, transform in
            HStack {
              Text(transform.title).lineLimit(1)
              Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(index == vm.transformSelection ? Color.accentColor.opacity(0.25) : .clear,
                        in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .onTapGesture { vm.transformSelection = index; vm.applySelectedTransform() }
          }
        }
        .padding(6)
      }
    }
  }

  private var footer: some View {
    HStack(spacing: 10) {
      if let message = vm.message {
        Text(message).foregroundStyle(.orange)
      } else if vm.mode == .transforms {
        Text("↩ apply & paste   ⇥/esc back")
      } else if vm.selectedHasOCRText {
        Text("↩ paste image   ⇧⌘↩ paste text   ⌥↩ copy   ⌘P pin   ⌘⌫ delete")
      } else {
        Text("↩ paste   ⌥↩ copy   ⇥ transform   ⌘P pin   ⌘⌫ delete")
      }
      Spacer()
      Toggle("Plain text", isOn: $settings.plainTextDefault)
        .toggleStyle(.checkbox)
    }
    .font(.caption)
    .foregroundStyle(.secondary)
    .padding(.horizontal, 12).padding(.vertical, 7)
  }
}

private struct EntryRow: View {
  let entry: ClipboardEntry
  let text: String
  let ocrSnippet: String?  // already masked when the entry is flagged
  let index: Int
  let selected: Bool

  var body: some View {
    HStack(spacing: 8) {
      if entry.findings.isEmpty {
        Image(systemName: entry.kind == .image ? "photo" : "doc.text").frame(width: 18).foregroundStyle(.secondary)
      } else {
        Image(systemName: "checkmark.shield.fill").frame(width: 18).foregroundStyle(.orange)
          .help("Contains sensitive data — shown masked")
      }
      if entry.kind == .image, let data = entry.imagePNG, let image = NSImage(data: data) {
        Image(nsImage: image).resizable().scaledToFit().frame(height: 28)
        if let ocrSnippet {
          Text("TEXT").font(.caption2.weight(.semibold))
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(Color.secondary.opacity(0.2), in: RoundedRectangle(cornerRadius: 3))
            .foregroundStyle(.secondary)
            .help("Text recognised in this image — ⇧⌘↩ pastes it")
          Text(ocrSnippet).lineLimit(1).truncationMode(.tail).foregroundStyle(.secondary)
        }
      } else {
        Text(text).lineLimit(1).truncationMode(.tail)
      }
      Spacer(minLength: 8)
      if entry.pinned { Image(systemName: "pin.fill").font(.caption).foregroundStyle(.secondary) }
      if index < 9 { Text("⌘\(index + 1)").font(.caption).foregroundStyle(.tertiary) }
    }
    .padding(.horizontal, 10).padding(.vertical, 7)
    .background(selected ? Color.accentColor.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 6))
  }
}
