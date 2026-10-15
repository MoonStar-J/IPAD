import SwiftUI

struct ObjectManagerView: View {
    @AppStorage(AppLanguage.key) private var appLanguage: AppLanguage = .korean
    let noteID: UUID
    let pageID: UUID
    let selectedID: UUID?
    var undoManager: UndoManager? = nil
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
                                    store.updateElement(noteID: noteID, pageID: pageID, element: updated, undoManager: undoManager)
                                }
                            } label: {
                                HStack {
                                    Label(element.kind == .text ? element.text : localized("사진", language: appLanguage), systemImage: element.kind == .text ? "textformat" : "photo").lineLimit(2)
                                    Spacer()
                                    if element.id == selectedID { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor) }
                                }
                            }
                        }
                        .onDelete { offsets in
                            undoManager?.beginUndoGrouping()
                            for offset in offsets { store.setAIElement(noteID: noteID, pageID: pageID, element: page.elements[offset], present: false, undoManager: undoManager) }
                            undoManager?.endUndoGrouping()
                        }
                    }
                } else {
                    ContentUnavailableView(localized("삽입한 항목이 없습니다", language: appLanguage), systemImage: "square.on.square", description: Text(localized("상단의 + 버튼에서 텍스트나 사진을 추가하세요.", language: appLanguage)))
                }
            }
            .navigationTitle(localized("텍스트와 사진", language: appLanguage))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(localized("완료", language: appLanguage)) { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) { EditButton() }
            }
            .storeErrorAlert()
        }
    }
}

struct ElementForm: View {
    @AppStorage(AppLanguage.key) private var appLanguage: AppLanguage = .korean
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
                Section(localized("텍스트", language: appLanguage)) {
                    if element.isRenderedText { Text(element.text).textSelection(.enabled) }
                    else { TextEditor(text: $element.text).frame(minHeight: 180)
                        .font(.system(size: element.fontSize))
                        .accessibilityLabel(localized("삽입할 텍스트", language: appLanguage))
                    Stepper(localized("글자 크기 %@", "\(Int(element.fontSize))", language: appLanguage), value: $element.fontSize, in: 12...72, step: 2) }
                }
            }
            Section {
                if page.isInfinite {
                    coordinateField(localized("가로 위치", language: appLanguage), value: $element.x)
                    coordinateField(localized("세로 위치", language: appLanguage), value: $element.y)
                    coordinateField(localized("너비", language: appLanguage), value: $element.width)
                    coordinateField(localized("높이", language: appLanguage), value: $element.height)
                } else {
                valueSlider(localized("가로 위치", language: appLanguage), value: $element.x, range: 0...max(1, page.width - element.width))
                valueSlider(localized("세로 위치", language: appLanguage), value: $element.y, range: 0...max(1, page.height - element.height))
                valueSlider(localized("너비", language: appLanguage), value: $element.width, range: 40...max(40, page.width))
                valueSlider(localized("높이", language: appLanguage), value: $element.height, range: 40...max(40, page.height))
                }
            } header: { Text(localized("위치와 크기", language: appLanguage)) } footer: {
                Text(localized("용지에서 ‘텍스트·사진 이동’을 켜면 항목을 끌어서 옮길 수 있습니다. 텍스트가 잘리면 높이를 늘려주세요.", language: appLanguage))
            }
        }
        .navigationTitle(element.kind == .text ? localized("텍스트 편집", language: appLanguage) : localized("사진 편집", language: appLanguage))
        .navigationBarTitleDisplayMode(.inline)
        .storeErrorAlert()
        .toolbar {
            if !embedded { ToolbarItem(placement: .cancellationAction) { Button(localized("취소", language: appLanguage)) { dismiss() } } }
            ToolbarItem(placement: .confirmationAction) {
                Button(localized("저장", language: appLanguage)) {
                    guard [element.x, element.y, element.width, element.height].allSatisfy(\.isFinite), element.width > 0, element.height > 0 else { return }
                    if !page.isInfinite {
                    element.width = min(element.width, page.width)
                    element.height = min(element.height, page.height)
                    element.x = min(max(0, element.x), max(0, page.width - element.width))
                    element.y = min(max(0, element.y), max(0, page.height - element.height))
                    }
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
    private func coordinateField(_ title: String, value: Binding<Double>) -> some View {
        HStack {
            Text(title)
            TextField(title, value: value, format: .number).multilineTextAlignment(.trailing)
                .keyboardType(.numbersAndPunctuation)
        }
    }
}
