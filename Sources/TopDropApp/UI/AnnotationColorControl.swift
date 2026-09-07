@preconcurrency import AppKit
import SwiftUI
import TopDropCore

/// Compact annotation color editor combining macOS's native color panel with
/// a paste-friendly hexadecimal field.
struct AnnotationColorControl: View {
    @Binding private var color: AnnotationColor
    @State private var hexText: String
    @FocusState private var isEditingHex: Bool

    init(color: Binding<AnnotationColor>) {
        _color = color
        _hexText = State(initialValue: color.wrappedValue.hexString)
    }

    private var parsedHex: AnnotationColor? {
        AnnotationColor(hexString: hexText)
    }

    private var hasInvalidHex: Bool {
        parsedHex == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                ColorPicker(
                    "Annotation color",
                    selection: Binding<Color>(
                        get: { swiftUIColor(for: color) },
                        set: { newColor in
                            applyPickerColor(newColor)
                        }
                    ),
                    supportsOpacity: true
                )
                .labelsHidden()
                .help("Open the macOS color picker, including the screen eyedropper")

                TextField("#RRGGBB", text: $hexText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
                    .frame(width: 100)
                    .focused($isEditingHex)
                    .overlay {
                        if hasInvalidHex {
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(.red, lineWidth: 1.5)
                                .allowsHitTesting(false)
                        }
                    }
                    .onChange(of: hexText) { _, newValue in
                        guard let parsed = AnnotationColor(hexString: newValue) else { return }
                        if parsed != color {
                            color = parsed
                        }
                    }
                    .onSubmit(finalizeHexEntry)
                    .help(
                        hasInvalidHex
                            ? "Enter #RRGGBB or #RRGGBBAA"
                            : "Hex color: #RRGGBB or #RRGGBBAA"
                    )
                    .accessibilityLabel("Hex annotation color")
                    .accessibilityValue(hasInvalidHex ? "Invalid hex color" : hexText)
            }

            HStack(spacing: 5) {
                ForEach(Self.quickColors) { preset in
                    Button {
                        color = preset.color
                        hexText = preset.color.hexString
                    } label: {
                        Circle()
                            .fill(swiftUIColor(for: preset.color))
                            .frame(width: 18, height: 18)
                            .overlay {
                                Circle()
                                    .stroke(
                                        .primary.opacity(preset.color == color ? 0.95 : 0.28),
                                        lineWidth: preset.color == color ? 2.5 : 1)
                            }
                            .overlay {
                                if preset.color == color {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 8, weight: .black))
                                        .foregroundStyle(preset.usesDarkCheckmark ? .black : .white)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .help(preset.name)
                    .accessibilityLabel("(preset.name) annotation color")
                    .accessibilityAddTraits(preset.color == color ? .isSelected : [])
                }
            }
        }
        .onChange(of: color) { _, newColor in
            let canonical = newColor.hexString
            if hexText != canonical {
                hexText = canonical
            }
        }
        .onChange(of: isEditingHex) { _, isEditing in
            if !isEditing {
                finalizeHexEntry()
            }
        }
    }

    private func finalizeHexEntry() {
        guard let parsed = parsedHex else {
            hexText = color.hexString
            return
        }
        if parsed != color {
            color = parsed
        }
        hexText = parsed.hexString
    }

    private func applyPickerColor(_ pickerColor: Color) {
        let nativeColor = NSColor(pickerColor)
        guard let sRGB = nativeColor.usingColorSpace(.sRGB) else { return }
        let updated = AnnotationColor(
            red: Double(sRGB.redComponent),
            green: Double(sRGB.greenComponent),
            blue: Double(sRGB.blueComponent),
            alpha: Double(sRGB.alphaComponent)
        )
        guard updated.isValid else { return }
        color = updated
        hexText = updated.hexString
    }

    private func swiftUIColor(for annotationColor: AnnotationColor) -> Color {
        Color(
            .sRGB,
            red: annotationColor.red,
            green: annotationColor.green,
            blue: annotationColor.blue,
            opacity: annotationColor.alpha
        )
    }

    private struct QuickColor: Identifiable {
        let name: String
        let color: AnnotationColor
        let usesDarkCheckmark: Bool

        var id: String { name }
    }

    private static let quickColors = [
        QuickColor(name: "Black", color: .black, usesDarkCheckmark: false),
        QuickColor(name: "White", color: .white, usesDarkCheckmark: true),
        QuickColor(name: "Gray", color: .gray, usesDarkCheckmark: false),
        QuickColor(name: "Red", color: .red, usesDarkCheckmark: false),
        QuickColor(name: "Orange", color: .orange, usesDarkCheckmark: true),
        QuickColor(name: "Yellow", color: .yellow, usesDarkCheckmark: true),
        QuickColor(name: "Blue", color: .blue, usesDarkCheckmark: false),
        QuickColor(name: "Green", color: .green, usesDarkCheckmark: true),
        QuickColor(name: "Purple", color: .purple, usesDarkCheckmark: false),
    ]
}
