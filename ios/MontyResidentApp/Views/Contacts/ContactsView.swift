import SwiftUI
import UIKit

@MainActor
@Observable
final class ContactsViewModel {
    var contacts: [StaffContact] = []
    var loading = true
    var error: String?

    func load(propertyId: String) async {
        loading = true; error = nil
        do { contacts = try await MontyResidentAppService.fetchContacts(propertyId: propertyId) }
        catch { self.error = error.localizedDescription }
        loading = false
    }
}

struct ContactsView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var vm = ContactsViewModel()

    private let horizontalPadding: CGFloat = 16

    var body: some View {
        ZStack {
            AtmosphericBackground()
            content
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .task(id: app.activeUnitId) { await reload() }
    }

    @ViewBuilder
    private var content: some View {
        if vm.loading && vm.contacts.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    VStack(spacing: 10) {
                        ForEach(0..<5, id: \.self) { _ in skeletonRow }
                    }
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.top, 8)
            }
        } else if let err = vm.error, vm.contacts.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    ZStack {
                        premiumCardBackground(radius: 18)
                        ErrorState(message: err) { Task { await reload() } }
                            .padding(.vertical, 8)
                    }
                    .clipShape(.rect(cornerRadius: 18))
                    .shadow(color: Theme.cardDropShadow, radius: 14, x: 0, y: 6)
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.top, 8)
                .padding(.bottom, 110)
            }
            .refreshable { await reload() }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    header
                    if vm.contacts.isEmpty {
                        emptyCard
                    } else {
                        contactsSection
                    }
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.top, 8)
                .padding(.bottom, 110)
            }
            .refreshable { await reload() }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                backButton
                Spacer()
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Building")
                    .font(.system(size: 30, weight: .bold))
                    .tracking(-0.6)
                    .foregroundStyle(Theme.textPrimary)
                Text("Management & on-site staff")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.chrome(0.55))
            }
        }
        .padding(.top, 4)
        .padding(.bottom, 4)
    }

    private var backButton: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            dismiss()
        } label: {
            Image(systemName: "chevron.left")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 36, height: 36)
                .background(Circle().fill(Theme.premiumCard))
                .overlay(Circle().stroke(Color.chrome(0.08), lineWidth: 0.6))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Sections

    private var contactsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("STAFF & MANAGEMENT", count: vm.contacts.count)
            VStack(spacing: 10) {
                ForEach(vm.contacts) { row($0) }
            }
        }
    }

    private func sectionHeader(_ text: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(text)
                .font(.system(size: 11, weight: .heavy))
                .tracking(1.2)
                .foregroundStyle(Color.chrome(0.45))
            if count > 0 {
                Text("\(count)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.chrome(0.45))
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 4)
    }

    // MARK: - Row

    private func row(_ c: StaffContact) -> some View {
        ZStack {
            premiumCardBackground(radius: 16)
            HStack(spacing: 12) {
                Avatar(name: c.name, url: c.avatarURL, size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(c.name ?? "Staff")
                        .font(.system(size: 15.5, weight: .semibold))
                        .tracking(-0.2)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    if let r = c.displayRole {
                        Text(r)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.chrome(0.55))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                HStack(spacing: 8) {
                    if let p = c.phone, let url = URL(string: "tel:\(p.filter("+0123456789".contains))") {
                        Link(destination: url) {
                            actionCircle(systemImage: "phone")
                        }
                    }
                    if let e = c.email, let url = URL(string: "mailto:\(e)") {
                        Link(destination: url) {
                            actionCircle(systemImage: "envelope")
                        }
                    }
                }
            }
            .padding(14)
        }
        .clipShape(.rect(cornerRadius: 16))
        .shadow(color: Theme.cardDropShadow, radius: 14, x: 0, y: 6)
    }

    private func actionCircle(systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Theme.textPrimary)
            .frame(width: 36, height: 36)
            .background(Circle().fill(Color.chrome(0.06)))
            .overlay(Circle().stroke(Color.chrome(0.10), lineWidth: 0.6))
    }

    // MARK: - Empty

    private var emptyCard: some View {
        ZStack {
            premiumCardBackground(radius: 18)
            VStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.chrome(0.04))
                    Image(systemName: "person.2")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(Color.chrome(0.62))
                }
                .frame(width: 56, height: 56)

                VStack(spacing: 4) {
                    Text("No contacts yet")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Building staff and management contacts will appear here once your team adds them.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.chrome(0.55))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                }
            }
            .padding(.vertical, 28)
            .padding(.horizontal, 22)
            .frame(maxWidth: .infinity)
        }
        .clipShape(.rect(cornerRadius: 18))
    }

    // MARK: - Skeleton

    private var skeletonRow: some View {
        ZStack {
            premiumCardBackground(radius: 16)
            HStack(spacing: 12) {
                Circle().fill(Color.chrome(0.05))
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 8) {
                    RoundedRectangle(cornerRadius: 4).fill(Color.chrome(0.08))
                        .frame(height: 12).frame(maxWidth: 160, alignment: .leading)
                    RoundedRectangle(cornerRadius: 4).fill(Color.chrome(0.05))
                        .frame(height: 10).frame(maxWidth: 200, alignment: .leading)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
        }
        .frame(height: 76)
    }

    @ViewBuilder
    private func premiumCardBackground(radius: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(Theme.premiumCard)
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .stroke(Color.chrome(0.05), lineWidth: 0.6)
        }
    }

    private func reload() async {
        guard let pid = app.activePropertyId else { return }
        await vm.load(propertyId: pid)
    }
}
