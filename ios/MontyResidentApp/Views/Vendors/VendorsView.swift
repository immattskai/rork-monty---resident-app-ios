import SwiftUI
import UIKit

@MainActor
@Observable
final class VendorsViewModel {
    var vendors: [ResidentVendor] = []
    var loading = true
    var error: String?

    // AI search state
    var searchText: String = ""
    var recommendations: [VendorRecommendation] = []
    var searching = false
    var searchError: String?
    var hasSearched = false

    func loadDirectory(propertyId: String) async {
        loading = true
        error = nil
        do {
            vendors = try await MontyResidentAppService.fetchPropertyVendorsForResident(propertyId: propertyId)
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }

    func runSearch(propertyId: String) async {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        searching = true
        searchError = nil
        do {
            recommendations = try await MontyResidentAppService.recommendVendors(
                description: q,
                propertyId: propertyId
            )
            hasSearched = true
        } catch {
            recommendations = []
            searchError = error.localizedDescription
            hasSearched = true
        }
        searching = false
    }

    func clearSearch() {
        searchText = ""
        recommendations = []
        hasSearched = false
        searchError = nil
    }

    /// Vendors grouped alphabetically by category label.
    var groupedByCategory: [(category: String, vendors: [ResidentVendor])] {
        let groups = Dictionary(grouping: vendors) { v -> String in
            let raw = (v.category ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return raw.isEmpty ? "Other" : raw
        }
        return groups
            .map { (category: $0.key, vendors: $0.value) }
            .sorted { $0.category.localizedCaseInsensitiveCompare($1.category) == .orderedAscending }
    }
}

struct VendorsView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var vm = VendorsViewModel()
    @FocusState private var searchFocused: Bool

    private let horizontalPadding: CGFloat = 16

    var body: some View {
        ZStack {
            AtmosphericBackground()
            content
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .task(id: app.activeUnit?.property_id) { await reload() }
    }

    @ViewBuilder
    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                header
                aiSearchCard
                if vm.searching {
                    searchLoadingCard
                } else if vm.hasSearched {
                    recommendationsSection
                }
                directorySection
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.top, 8)
            .padding(.bottom, 110)
        }
        .refreshable { await reload() }
        .scrollDismissesKeyboard(.interactively)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { backButton; Spacer() }
            VStack(alignment: .leading, spacing: 4) {
                Text("Preferred Vendors")
                    .font(.system(size: 30, weight: .bold))
                    .tracking(-0.6)
                    .foregroundStyle(Theme.textPrimary)
                Text("Approved vendors for your building")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.chrome(0.55))
            }
        }
        .padding(.top, 4)
    }

    private var backButton: some View {
        Button {
            Haptics.tap()
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

    // MARK: - AI Search

    private var aiSearchCard: some View {
        ZStack {
            premiumCard(radius: 18)
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(LinearGradient(
                                colors: [Color(hex: 0x8B5CF6).opacity(0.18), Color(hex: 0x5B8DEF).opacity(0.18)],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            ))
                        Image(systemName: "sparkles")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Color(hex: 0x8B5CF6))
                    }
                    .frame(width: 38, height: 38)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Find the right vendor")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Text("Describe the issue — we'll match a vendor")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.chrome(0.55))
                    }
                    Spacer(minLength: 0)

                    if vm.hasSearched {
                        Button {
                            Haptics.tap()
                            vm.clearSearch()
                            searchFocused = false
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 18, weight: .regular))
                                .foregroundStyle(Color.chrome(0.40))
                        }
                        .buttonStyle(.plain)
                    }
                }

                HStack(spacing: 8) {
                    TextField(
                        "Describe your issue… e.g. 'My kitchen faucet is leaking'",
                        text: Binding(get: { vm.searchText }, set: { vm.searchText = $0 }),
                        axis: .vertical
                    )
                    .focused($searchFocused)
                    .lineLimit(1...3)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.chrome(0.04))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.chrome(0.06), lineWidth: 0.6)
                    )
                    .submitLabel(.search)
                    .onSubmit { triggerSearch() }
                }

                Button(action: triggerSearch) {
                    HStack(spacing: 8) {
                        if vm.searching {
                            ProgressView().controlSize(.small).tint(.white)
                        } else {
                            Image(systemName: "sparkles")
                                .font(.system(size: 14, weight: .semibold))
                        }
                        Text(vm.searching ? "Searching…" : "Search")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [Color(hex: 0x8B5CF6), Color(hex: 0x5B8DEF)],
                                    startPoint: .leading, endPoint: .trailing
                                )
                            )
                    )
                    .opacity(canSearch ? 1 : 0.5)
                }
                .buttonStyle(.plain)
                .disabled(!canSearch)
            }
            .padding(14)
        }
        .clipShape(.rect(cornerRadius: 18))
    }

    private var canSearch: Bool {
        !vm.searching && !vm.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func triggerSearch() {
        guard let pid = app.activePropertyId else { return }
        guard canSearch else { return }
        Haptics.tap()
        searchFocused = false
        Task { await vm.runSearch(propertyId: pid) }
    }

    private var searchLoadingCard: some View {
        ZStack {
            premiumCard(radius: 16)
            HStack(spacing: 12) {
                ProgressView().controlSize(.regular).tint(Color(hex: 0x8B5CF6))
                Text("Finding the best vendors for you…")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.chrome(0.65))
                Spacer(minLength: 0)
            }
            .padding(14)
        }
        .clipShape(.rect(cornerRadius: 16))
    }

    // MARK: - Recommendations

    @ViewBuilder
    private var recommendationsSection: some View {
        if let err = vm.searchError {
            ZStack {
                premiumCard(radius: 16)
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(Color(hex: 0xE8B454))
                    Text(err)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.chrome(0.65))
                    Spacer()
                }
                .padding(14)
            }
            .clipShape(.rect(cornerRadius: 16))
        } else if vm.recommendations.isEmpty {
            ZStack {
                premiumCard(radius: 16)
                VStack(alignment: .leading, spacing: 4) {
                    Text("No specific vendor match found.")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Browse the full directory below.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.chrome(0.55))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
            }
            .clipShape(.rect(cornerRadius: 16))
        } else {
            VStack(alignment: .leading, spacing: 10) {
                sectionHeader("RECOMMENDED FOR YOU", count: vm.recommendations.count)
                VStack(spacing: 10) {
                    ForEach(Array(vm.recommendations.enumerated()), id: \.element.vendor_id) { idx, rec in
                        RecommendationCard(rank: idx + 1, rec: rec)
                    }
                }
            }
        }
    }

    // MARK: - Directory

    @ViewBuilder
    private var directorySection: some View {
        if vm.loading && vm.vendors.isEmpty {
            VStack(spacing: 10) {
                ForEach(0..<4, id: \.self) { _ in skeletonRow }
            }
        } else if let err = vm.error, vm.vendors.isEmpty {
            ZStack {
                premiumCard(radius: 18)
                ErrorState(message: err) { Task { await reload() } }
                    .padding(.vertical, 8)
            }
            .clipShape(.rect(cornerRadius: 18))
        } else if vm.vendors.isEmpty {
            emptyDirectoryCard
        } else {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(vm.groupedByCategory, id: \.category) { group in
                    VStack(alignment: .leading, spacing: 10) {
                        sectionHeader(group.category.uppercased(), count: group.vendors.count)
                        VStack(spacing: 10) {
                            ForEach(group.vendors) { v in
                                VendorRow(vendor: v)
                            }
                        }
                    }
                }
            }
        }
    }

    private var emptyDirectoryCard: some View {
        ZStack {
            premiumCard(radius: 18)
            VStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.chrome(0.04))
                    Image(systemName: "hammer")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(Color.chrome(0.62))
                }
                .frame(width: 56, height: 56)
                VStack(spacing: 4) {
                    Text("No vendors yet")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Your building hasn't added any preferred vendors yet.")
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

    private var skeletonRow: some View {
        ZStack {
            premiumCard(radius: 16)
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 10).fill(Color.chrome(0.05))
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 8) {
                    RoundedRectangle(cornerRadius: 4).fill(Color.chrome(0.08))
                        .frame(height: 12).frame(maxWidth: 180, alignment: .leading)
                    RoundedRectangle(cornerRadius: 4).fill(Color.chrome(0.05))
                        .frame(height: 10).frame(maxWidth: 140, alignment: .leading)
                }
                Spacer()
            }
            .padding(14)
        }
        .frame(height: 78)
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
    }

    @ViewBuilder
    private func premiumCard(radius: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(Theme.premiumCard)
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .stroke(Color.chrome(0.05), lineWidth: 0.6)
        }
    }

    private func reload() async {
        guard let pid = app.activePropertyId else {
            vm.loading = false
            return
        }
        await vm.loadDirectory(propertyId: pid)
    }
}

// MARK: - Vendor Row (directory)

private struct VendorRow: View {
    let vendor: ResidentVendor

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Theme.premiumCard)
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.chrome(0.05), lineWidth: 0.6)

            VStack(alignment: .leading, spacing: 10) {
                Text(vendor.name ?? "Vendor")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)

                if let d = vendor.description?.trimmingCharacters(in: .whitespacesAndNewlines), !d.isEmpty {
                    Text(d)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.chrome(0.58))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }

                if let c = vendor.primaryContact {
                    VendorContactRow(contact: c)
                        .padding(.top, 2)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .clipShape(.rect(cornerRadius: 16))
        .shadow(color: Theme.cardDropShadow, radius: 10, x: 0, y: 4)
    }
}

// MARK: - Recommendation Card

private struct RecommendationCard: View {
    let rank: Int
    let rec: VendorRecommendation

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Theme.premiumCard)
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [Color(hex: 0x8B5CF6).opacity(0.45), Color(hex: 0x5B8DEF).opacity(0.25)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )

            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [Color(hex: 0x8B5CF6), Color(hex: 0x5B8DEF)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing
                                )
                            )
                        Text("\(rank)")
                            .font(.system(size: 13, weight: .heavy, design: .rounded))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 26, height: 26)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(rec.name)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(2)
                        if let cat = rec.category?.trimmingCharacters(in: .whitespacesAndNewlines), !cat.isEmpty {
                            Text(cat.uppercased())
                                .font(.system(size: 9.5, weight: .heavy))
                                .tracking(0.9)
                                .foregroundStyle(Color(hex: 0x8B5CF6))
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Capsule().fill(Color(hex: 0x8B5CF6).opacity(0.12)))
                        }
                    }
                    Spacer(minLength: 0)
                }

                if !rec.reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    HStack(alignment: .top, spacing: 8) {
                        Rectangle()
                            .fill(Color(hex: 0x8B5CF6).opacity(0.5))
                            .frame(width: 2)
                            .clipShape(.rect(cornerRadius: 1))
                        Text("\u{201C}\(rec.reasoning)\u{201D}")
                            .italic()
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.chrome(0.65))
                            .multilineTextAlignment(.leading)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }

                if let c = rec.primaryContact {
                    VendorContactRow(contact: c)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .clipShape(.rect(cornerRadius: 18))
        .shadow(color: Theme.cardDropShadow, radius: 12, x: 0, y: 6)
    }
}

// MARK: - Contact row (shared)

private struct VendorContactRow: View {
    let contact: ResidentVendorContact

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let name = contact.contact_name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                Text(name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
            }
            HStack(spacing: 8) {
                if let phone = contact.phone?.trimmingCharacters(in: .whitespacesAndNewlines), !phone.isEmpty {
                    ContactPill(icon: "phone.fill", label: phone) {
                        openURL("tel:\(phone.filter { $0.isNumber || $0 == "+" })")
                    }
                }
                if let email = contact.email?.trimmingCharacters(in: .whitespacesAndNewlines), !email.isEmpty {
                    ContactPill(icon: "envelope.fill", label: email) {
                        openURL("mailto:\(email)")
                    }
                }
            }
        }
    }

    private func openURL(_ s: String) {
        Haptics.tap()
        guard let url = URL(string: s) else { return }
        UIApplication.shared.open(url)
    }
}

private struct ContactPill: View {
    let icon: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                Text(label)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.chrome(0.06)))
            .overlay(Capsule().stroke(Color.chrome(0.08), lineWidth: 0.6))
        }
        .buttonStyle(.plain)
    }
}
