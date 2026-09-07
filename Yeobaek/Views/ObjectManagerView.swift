import SwiftUI

struct ObjectManagerView: View {
    let noteID: UUID
    let pageID: UUID
    let selectedID: UUID?
    @EnvironmentObject private var store: NoteStore
    @Environment(\.dismiss) private var dismiss
    private var page: NotePage? { store.note(noteID)?.pages.first { $0.id == pageID } }

    var body: some View {
        NavigationStack {
            Group {
                if let page, !page.elements.isEmpty {
                    List {
                        ForEach(page.elements) { element in
                            NavigationLink {
                                ElementForm(element: element, page: page, embedded: true) { updated in
                                    store.updatePage(noteID: noteID, pageID: pageID) { page in
                                        guard let index = page.elements.firstIndex(where: { $0.id == updated.id }) else { return }
                                        page.elements[index] = updated
                                    }
                                }
                            } label: {
                                HStack {
                                    Label(element.kind == .text ? element.text : "사진", systemImage: element.kind == .text ? "textformat" : "photo").lineLimit(2)
                                    Spacer()
                                    if element.id == selectedID { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor) }
                                }
                            }
                        }
                        .onDelete { offsets in
                            store.updatePage(noteID: noteID, pageID: pageID) { $0.elements.remove(atOffsets: offsets) }
                        }
                    }
                } else {
                    ContentUnavailableView("삽입한 항목이 없습니다", systemImage: "square.on.square", description: Text("상단의 + 버튼에서 텍스트나 사진을 추가하세요."))
                }
            }
            .navigationTitle("텍스트와 사진")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("완료") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) { EditButton() }
            }
            .storeErrorAlert()
        }
    }
}

struct ElementForm: View {
    @State var element: PageElement
    let page: NotePage
    var embedded = false
    var onSave: (PageElement) -> Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if embedded { form }
        else { NavigationStack { form } }
    }

    private var form: some View {
        Form {
            if element.kind == .text {
                Section("텍스트") {
                    TextEditor(text: $element.text).frame(minHeight: 180)
                        .font(.system(size: element.fontSize))
                        .accessibilityLabel("삽입할 텍스트")
                    Stepper("글자 크기 \(Int(element.fontSize))", value: $element.fontSize, in: 12...72, step: 2)
                }
            }
            Section {
                valueSlider("가로 위치", value: $element.x, range: 0...max(1, page.width - element.width))
                valueSlider("세로 위치", value: $element.y, range: 0...max(1, page.height - element.height))
                valueSlider("너비", value: $element.width, range: 40...max(40, page.width))
                valueSlider("높이", value: $element.height, range: 40...max(40, page.height))
            } header: { Text("위치와 크기") } footer: {
                Text("용지에서 ‘텍스트·사진 이동’을 켜면 항목을 끌어서 옮길 수 있습니다. 텍스트가 잘리면 높이를 늘려주세요.")
            }
        }
        .navigationTitle(element.kind == .text ? "텍스트 편집" : "사진 편집")
        .navigationBarTitleDisplayMode(.inline)
        .storeErrorAlert()
        .toolbar {
            if !embedded { ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } } }
            ToolbarItem(placement: .confirmationAction) {
                Button("저장") {
                    element.width = min(element.width, page.width)
                    element.height = min(element.height, page.height)
                    element.x = min(max(0, element.x), max(0, page.width - element.width))
                    element.y = min(max(0, element.y), max(0, page.height - element.height))
                    if onSave(element) { dismiss() }
                }.bold().disabled(element.kind == .text && element.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func valueSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text(title); Spacer(); Text("\(Int(value.wrappedValue))").foregroundStyle(.secondary).monospacedDigit() }
            Slider(value: value, in: range).accessibilityLabel(title)
        }
    }
}
