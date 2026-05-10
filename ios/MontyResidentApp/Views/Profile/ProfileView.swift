import SwiftUI

struct ProfileView: View {
    @Environment(AppState.self) private var app
    @Environment(AppearanceManager.self) private var appearance
    @State private var confirmingSignOut = false

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.xl) {
                    headerCard
                    unitsSection
                    preferencesSection
                    Button {
                        confirmingSignOut = true
                    } label: {
                        Text("Sign out")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Theme.danger)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(Theme.surface)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(Theme.border, lineWidth: 0.5)
                            )
                    }
                    .padding(.horizontal, Theme.Space.lg)
                }
                .padding(.top, Theme.Space.md)
                .padding(.bottom, Theme.Space.xxl)
            }
        }
        .navigationTitle("Profile")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Sign out of MontyResidentApp?", isPresented: $confirmingSignOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) {
                Task { await app.signOut() }
            }
            Button("Cancel", role: .cancel) { }
        }
    }

    private var headerCard: some View {
        GlassCard(padding: Theme.Space.xl) {
            HStack(spacing: Theme.Space.md) {
                Avatar(name: app.profile?.full_name, size: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text(app.profile?.full_name ?? "Resident")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    if let e = app.profile?.email ?? SupabaseAPI.shared.session?.email {
                        Text(e).font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                    }
                }
                Spacer()
            }
        }
        .padding(.horizontal, Theme.Space.lg)
    }

    private var preferencesSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            SectionHeader(title: "Preferences")
            appearanceCard
                .padding(.horizontal, Theme.Space.lg)
            NavigationLink(value: HomeRoute.notificationSettings) {
                GlassCard {
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Theme.surfaceSunken)
                            Image(systemName: "bell.fill")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(Theme.textPrimary)
                        }
                        .frame(width: 36, height: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Notifications")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(Theme.textPrimary)
                            Text("Choose what alerts you receive")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textSecondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, Theme.Space.lg)
        }
    }

    private var appearanceCard: some View {
        @Bindable var appearanceBindable = appearance
        return GlassCard {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Theme.surfaceSunken)
                    Image(systemName: "moon.stars.fill")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                }
                .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Appearance")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Choose your theme")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Picker("Appearance", selection: $appearanceBindable.mode) {
                    ForEach(AppearanceManager.Mode.allCases) { m in
                        Text(m.label).tag(m)
                    }
                }
                .pickerStyle(.menu)
                .tint(Theme.textPrimary)
            }
        }
    }

    @ViewBuilder
    private var unitsSection: some View {
        if !app.units.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                SectionHeader(title: "My units")
                VStack(spacing: Theme.Space.sm) {
                    ForEach(app.units) { unit in
                        Button { app.setActiveUnit(unit.id) } label: {
                            GlassCard {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(unit.displayLabel)
                                            .font(.system(size: 15, weight: .medium))
                                            .foregroundStyle(Theme.textPrimary)
                                        if let p = unit.property?.name {
                                            Text(p).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                                        }
                                    }
                                    Spacer()
                                    if app.activeUnitId == unit.id {
                                        StatusPill(text: "Active", tone: .success)
                                    }
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, Theme.Space.lg)
            }
        }
    }
}
