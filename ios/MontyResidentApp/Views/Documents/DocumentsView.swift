import SwiftUI
import UIKit

private let CATEGORY_LABELS: [String: String] = [
    "offering_plan": "Offering Plan",
    "bylaws": "Bylaws",
    "insurance": "Insurance",
    "service_contract": "Service Contract",
    "permit": "Permit / Certificate",
    "warranty": "Warranty",
    "lease": "Lease",
    "tax": "Tax",
    "house_rules": "House Rules",
    "financials": "Financials",
    "meeting_minutes": "Meeting Minutes",
    "other": "Other",
]

private func categoryLabel(_ key: String?) -> String {
    guard let key, !key.isEmpty else { return "Other" }
    return CATEGORY_LABELS[key] ?? key.replacingOccurrences(of: "_", with: " ").capitalized
}

private func fileIcon(forType type: String?, category: String?) -> String {
    let t = (type ?? "").lowercased()
    if t.contains("pdf") { return "doc.richtext" }
    if t.contains("image") || t.contains("png") || t.contains("jpg") || t.contains("jpeg") || t.contains("heic") {
        return "photo"
    }
    if t.contains("sheet") || t.contains("excel") || t.contains("csv") { return "tablecells" }
    if t.contains("word") || t.contains("doc") { return "doc.text" }
    if t.contains("zip") || t.contains("archive") { return "doc.zipper" }
    switch category {
    case "insurance": return "shield"
    case "bylaws", "house_rules": return "book.closed"
    case "financials", "tax": return "chart.line.uptrend.xyaxis"
    case "meeting_minutes": return "person.2.wave.2"
    case "permit": return "checkmark.seal"
    case "warranty": return "wrench.and.screwdriver"
    case "lease": return "house"
    case "service_contract": return "scroll"
    default: return "doc.text"
    }
}

private func formatFileSize(_ bytes: Int?) -> String? {
    guard let bytes, bytes > 0 else { return nil }
    if bytes < 1024 { return "\(bytes) B" }
    if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024.0) }
    return String(format: "%.1f MB", Double(bytes) / (1024.0 * 1024.0))
}

private enum ExpirationStatus { case ok, expiringSoon, expired }

private func expirationStatus(_ raw: String?) -> (ExpirationStatus, Date)? {
    guard let raw, !raw.isEmpty else { return nil }
    let date = Fmt.parseDay(raw) ?? Fmt.parseDate(raw)
    guard let date else { return nil }
    let days = Int(date.timeIntervalSince(Date()) / 86400)
    if days < 0 { return (.expired, date) }
    if days <= 30 { return (.expiringSoon, date) }
    return (.ok, date)
}

private let expiryFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "MMM d, yyyy"
    return f
}()

@MainActor
@Observable
final class DocumentsViewModel {
    var docs: [DocumentItem] = []
    var loading = true
    var error: String?
    var selectedCategory: String? = nil // nil == All

    func load(propertyId: String) async {
        loading = true; error = nil
        do {
            docs = try await MontyResidentAppService.fetchResidentDocuments(propertyId: propertyId)
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }

    var availableCategories: [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for d in docs {
            let key = d.category ?? "other"
            if seen.insert(key).inserted { ordered.append(key) }
        }
        return ordered
    }

    var filteredDocs: [DocumentItem] {
        guard let cat = selectedCategory else { return docs }
        return docs.filter { ($0.category ?? "other") == cat }
    }
}

struct DocumentsView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var vm = DocumentsViewModel()
    @State private var openURL: IdentifiableURL?
    @State private var shareURL: IdentifiableURL?
    @State private var openingId: String?
    @State private var toast: String?

    private let horizontalPadding: CGFloat = 16

    var body: some View {
        ZStack {
            AtmosphericBackground()
            content
        }
        .montyToast($toast)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(item: $openURL) { item in SafariView(url: item.url).ignoresSafeArea() }
        .sheet(item: $shareURL) { item in ShareSheet(items: [item.url]) }
        .task(id: app.activeUnitId) { await reload() }
    }

    @ViewBuilder
    private var content: some View {
        if vm.loading && vm.docs.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    VStack(spacing: 10) {
                        ForEach(0..<6, id: \.self) { _ in skeletonRow }
                    }
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.top, 8)
            }
        } else if let err = vm.error, vm.docs.isEmpty {
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
                LazyVStack(alignment: .leading, spacing: 18, pinnedViews: []) {
                    header
                    if !vm.availableCategories.isEmpty {
                        filterPills
                    }
                    if vm.filteredDocs.isEmpty {
                        emptyCard
                    } else {
                        docsSection
                    }
                }
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
                Text("Documents")
                    .font(.system(size: 30, weight: .bold))
                    .tracking(-0.6)
                    .foregroundStyle(Theme.textPrimary)
                Text("Bylaws, rules, insurance, and forms")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.chrome(0.55))
            }
        }
        .padding(.horizontal, horizontalPadding)
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

    // MARK: - Filters

    private var filterPills: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                NeutralFilterChip(label: "All", count: vm.docs.count, isSelected: vm.selectedCategory == nil) {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(Theme.Motion.smooth) { vm.selectedCategory = nil }
                }
                ForEach(vm.availableCategories, id: \.self) { key in
                    let count = vm.docs.filter { ($0.category ?? "other") == key }.count
                    NeutralFilterChip(
                        label: categoryLabel(key),
                        count: count,
                        isSelected: vm.selectedCategory == key
                    ) {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        withAnimation(Theme.Motion.smooth) {
                            vm.selectedCategory = (vm.selectedCategory == key) ? nil : key
                        }
                    }
                }
            }
            .padding(.horizontal, horizontalPadding)
        }
    }

    // MARK: - Docs section

    private var docsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(
                vm.selectedCategory == nil ? "ALL DOCUMENTS" : categoryLabel(vm.selectedCategory).uppercased(),
                count: vm.filteredDocs.count
            )
            .padding(.horizontal, horizontalPadding)

            VStack(spacing: 10) {
                ForEach(vm.filteredDocs) { d in
                    DocumentRow(
                        doc: d,
                        isOpening: openingId == d.id,
                        onTap: { open(d) },
                        onShare: { share(d) }
                    )
                    .padding(.horizontal, horizontalPadding)
                }
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

    // MARK: - Empty

    private var emptyCard: some View {
        ZStack {
            premiumCardBackground(radius: 18)
            VStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.chrome(0.04))
                    Image(systemName: "doc.text")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(Color.chrome(0.62))
                }
                .frame(width: 56, height: 56)
                VStack(spacing: 4) {
                    Text(vm.selectedCategory == nil
                         ? "No documents yet"
                         : "No \(categoryLabel(vm.selectedCategory).lowercased()) documents")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(vm.selectedCategory == nil
                         ? "Bylaws, house rules, insurance, and more will appear here once your management team adds them."
                         : "Try switching filters to see other documents.")
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
        .padding(.horizontal, horizontalPadding)
    }

    // MARK: - Skeleton

    private var skeletonRow: some View {
        ZStack {
            premiumCardBackground(radius: 16)
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
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
        }
        .frame(height: 78)
        .padding(.horizontal, horizontalPadding)
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

    // MARK: - Actions

    private func reload() async {
        guard let pid = app.activePropertyId else { return }
        await vm.load(propertyId: pid)
    }

    private func open(_ d: DocumentItem) {
        guard let path = d.file_path, !path.isEmpty else {
            showToast("This document is unavailable.")
            return
        }
        openingId = d.id
        Task {
            defer { openingId = nil }
            do {
                let url = try await MontyResidentAppService.signedURL(forDocumentPath: path)
                openURL = IdentifiableURL(url: url)
            } catch {
                showToast("We couldn't open this document. Try again.")
            }
        }
    }

    private func share(_ d: DocumentItem) {
        guard let path = d.file_path, !path.isEmpty else {
            showToast("This document is unavailable.")
            return
        }
        Task {
            do {
                let url = try await MontyResidentAppService.signedURL(forDocumentPath: path)
                shareURL = IdentifiableURL(url: url)
            } catch {
                showToast("We couldn't share this document. Try again.")
            }
        }
    }

    private func showToast(_ text: String) {
        withAnimation(Theme.Motion.smooth) { toast = text }
    }
}

// MARK: - Neutral filter chip

private struct NeutralFilterChip: View {
    let label: String
    let count: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(label)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isSelected ? .white : Color.chrome(0.62))
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(isSelected ? Color.chrome(0.7) : Color.chrome(0.40))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Capsule().fill(
                    isSelected
                        ? Color(red: 26/255, green: 28/255, blue: 34/255)
                        : Theme.premiumCard.opacity(0.85)
                )
            )
            .overlay(
                Capsule().stroke(
                    isSelected ? Color.chrome(0.18) : Color.chrome(0.06),
                    lineWidth: 0.6
                )
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Row

private struct DocumentRow: View {
    let doc: DocumentItem
    let isOpening: Bool
    let onTap: () -> Void
    let onShare: () -> Void

    var body: some View {
        Button(action: onTap) {
            ZStack {
                cardBackground
                HStack(alignment: .top, spacing: 12) {
                    iconWell
                    VStack(alignment: .leading, spacing: 6) {
                        Text(doc.name ?? "Untitled document")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)

                        HStack(spacing: 6) {
                            categoryMicroLabel
                            if let size = formatFileSize(doc.file_size) {
                                dot
                                Text(size)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(Color.chrome(0.55))
                            }
                            if let date = Fmt.parseDate(doc.created_at) {
                                dot
                                Text(expiryFormatter.string(from: date))
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(Color.chrome(0.55))
                            }
                        }
                        .lineLimit(1)

                        if let pill = expiryPill { pill }
                    }
                    Spacer(minLength: 0)
                    if isOpening {
                        ProgressView()
                            .controlSize(.small)
                            .tint(Color.chrome(0.7))
                    } else {
                        Image(systemName: "arrow.up.forward")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.chrome(0.45))
                    }
                }
                .padding(14)
            }
            .clipShape(.rect(cornerRadius: 16))
            .shadow(color: Theme.cardDropShadow, radius: 14, x: 0, y: 6)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { onTap() } label: { Label("Open", systemImage: "arrow.up.forward.app") }
            Button { onShare() } label: { Label("Share", systemImage: "square.and.arrow.up") }
        }
    }

    private var cardBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Theme.premiumCard)
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.chrome(0.05), lineWidth: 0.6)
        }
    }

    private var iconWell: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.chrome(0.05))
            Image(systemName: fileIcon(forType: doc.file_type, category: doc.category))
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(Color.chrome(0.78))
        }
        .frame(width: 44, height: 44)
    }

    private var categoryMicroLabel: some View {
        Text(categoryLabel(doc.category).uppercased())
            .font(.system(size: 9.5, weight: .heavy))
            .tracking(0.9)
            .foregroundStyle(Color.chrome(0.62))
    }

    private var dot: some View {
        Text("·").font(.system(size: 11)).foregroundStyle(Color.chrome(0.30))
    }

    @ViewBuilder
    private var expiryPill: (some View)? {
        if (doc.category == "insurance" || doc.category == "house_rules"),
           let (status, date) = expirationStatus(doc.expiry_date) {
            let (label, color): (String, Color) = {
                switch status {
                case .expired: return ("EXPIRED \(expiryFormatter.string(from: date))", Color(hex: 0xF26A6A))
                case .expiringSoon: return ("EXPIRES \(expiryFormatter.string(from: date))", Color(hex: 0xE8B454))
                case .ok: return ("EXPIRES \(expiryFormatter.string(from: date))", Color.chrome(0.55))
                }
            }()
            HStack(spacing: 4) {
                Image(systemName: status == .expired ? "exclamationmark.triangle.fill" : "calendar")
                    .font(.system(size: 9, weight: .semibold))
                Text(label)
                    .font(.system(size: 10, weight: .heavy))
                    .tracking(0.6)
            }
            .foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.14)))
        } else {
            EmptyView()
        }
    }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

struct IdentifiableURL: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}
