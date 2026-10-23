import PFDesign
import SwiftUI

/// Settings → Customize deck: pick the turntable the player draws and the style of record on it. Both choices are
/// saved with `@AppStorage` (`DeckPreferences`), and the player reads the same keys.
struct CustomizeDeckView: View {
    @AppStorage(DeckPreferences.designKey) private var designID = DeckDesign.standard.id
    @AppStorage(DeckPreferences.recordStyleKey) private var recordStyleRaw = RecordStyle.standard.rawValue
    @Environment(\.isMonochrome) private var mono
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var typeSize

    private var theme: Theme { .look(stage: .deck, dark: scheme == .dark, monochrome: mono) }
    private var design: DeckDesign { DeckDesign.design(id: designID) }
    private var recordStyle: RecordStyle { RecordStyle(rawValue: recordStyleRaw) ?? .standard }
    /// The picker's selection, normalised so an unknown stored value shows the default.
    private var recordStyleBinding: Binding<String> {
        Binding(get: { recordStyle.rawValue }, set: { recordStyleRaw = $0 })
    }

    /// One column at accessibility text sizes, so a name and tagline are never squeezed.
    private var columns: [GridItem] {
        let count = typeSize.isAccessibilitySize ? 1 : 2
        return Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: count)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                DeckPreview(design: design, recordStyle: recordStyle, album: nil)
                    .frame(maxHeight: 240)
                    .frame(maxWidth: .infinity)
                    .padding(16)
                    .glassCard(theme)
                    .accessibilityHidden(true)

                section("Player") {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(DeckDesign.catalogue) { card($0) }
                    }
                    Text(design.blurb)
                        .font(.footnote)
                        .foregroundStyle(theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                section("Record") {
                    Picker("Record style", selection: recordStyleBinding) {
                        Text("Black vinyl").tag(RecordStyle.black.rawValue)
                        Text("Coloured").tag(RecordStyle.coloured.rawValue)
                        Text("Picture disc").tag(RecordStyle.picture.rawValue)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityLabel("Record style")
                    .accessibilityIdentifier("recordStylePicker")
                    Text(
                        "Black vinyl turns as calmly as a real LP. Picture disc prints the album across the whole record."
                    )
                    .font(.footnote)
                    .foregroundStyle(theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(theme.background.ignoresSafeArea())
        .foregroundStyle(theme.ink)
        .tint(theme.isMonochrome ? Theme.monochromeTint : theme.ink)
        .navigationTitle("Customize deck")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }

    private func card(_ item: DeckDesign) -> some View {
        let selected = item.id == design.id
        return Button {
            designID = item.id
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                DeckPreview(design: item, recordStyle: recordStyle, album: nil)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name).font(.subheadline.weight(.semibold))
                        Text(item.tagline).font(.caption).foregroundStyle(theme.inkSecondary)
                    }
                    Spacer(minLength: 0)
                    if selected {
                        Image(systemName: "checkmark.circle.fill").font(.subheadline)
                    }
                }
                .multilineTextAlignment(.leading)
            }
            .padding(10)
            .glassCard(theme)
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                        .strokeBorder(theme.ink.opacity(0.85), lineWidth: 2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: selected) { _, now in now }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.name), \(item.tagline)")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("deckDesign-\(item.id)")
    }

    fileprivate static let cornerRadius: CGFloat = 20
}

extension View {
    /// The Sound tab's glass, as a rounded card with a hairline edge.
    fileprivate func glassCard(_ theme: Theme) -> some View {
        background(SoundGlass(theme: theme))
            .clipShape(RoundedRectangle(cornerRadius: CustomizeDeckView.cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: CustomizeDeckView.cornerRadius, style: .continuous)
                    .strokeBorder(theme.hairline, lineWidth: 1)
            }
    }
}
