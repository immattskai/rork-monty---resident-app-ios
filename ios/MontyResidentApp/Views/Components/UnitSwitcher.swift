import SwiftUI

struct UnitSwitcher: View {
    @Environment(AppState.self) private var app
    @State private var presented = false

    private var label: String {
        app.activeUnit?.displayLabel ?? "—"
    }

    private var subLabel: String? {
        app.activeUnit?.property?.name
    }

    var body: some View {
        if app.units.count > 1 {
            Button {
                presented = true
            } label: {
                HStack(spacing: 6) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(label)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Theme.textPrimary)
                        if let sub = subLabel {
                            Text(sub)
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(
                    Capsule().fill(Theme.surface)
                )
                .overlay(Capsule().stroke(Theme.border, lineWidth: 0.5))
            }
            .sheet(isPresented: $presented) {
                UnitPickerSheet()
                    .presentationDetents([.medium])
                    .presentationBackground(Theme.background)
            }
        } else if let u = app.activeUnit {
            VStack(alignment: .leading, spacing: 0) {
                Text(u.displayLabel)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                if let p = u.property?.name {
                    Text(p)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }
}

private struct UnitPickerSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Switch unit")
                .font(.system(size: 22, weight: .semibold))
                .padding(.horizontal, Theme.Space.lg)
                .padding(.top, Theme.Space.lg)
                .padding(.bottom, Theme.Space.md)
            ScrollView {
                VStack(spacing: Theme.Space.sm) {
                    ForEach(app.units) { unit in
                        Button {
                            app.setActiveUnit(unit.id)
                            dismiss()
                        } label: {
                            GlassCard {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(unit.displayLabel)
                                            .font(.system(size: 16, weight: .medium))
                                            .foregroundStyle(Theme.textPrimary)
                                        if let p = unit.property?.name {
                                            Text(p)
                                                .font(.system(size: 13))
                                                .foregroundStyle(Theme.textSecondary)
                                        }
                                    }
                                    Spacer()
                                    if app.activeUnitId == unit.id {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundStyle(Theme.textPrimary)
                                    }
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, Theme.Space.lg)
                .padding(.bottom, Theme.Space.xl)
            }
        }
    }
}
