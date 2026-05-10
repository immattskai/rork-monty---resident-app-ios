import SwiftUI

@MainActor
@Observable
final class PackageDetailViewModel {
    var pkg: Package?
    var loading = true
    var error: String?

    func load(id: String) async {
        loading = true; error = nil
        do { pkg = try await MontyResidentAppService.fetchPackage(id: id) }
        catch { self.error = error.localizedDescription }
        loading = false
    }
}

struct PackageDetailView: View {
    let packageId: String
    @State private var vm = PackageDetailViewModel()

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            Group {
                if vm.loading && vm.pkg == nil {
                    VStack(spacing: 12) { SkeletonRow(height: 240); SkeletonRow(height: 120) }
                        .padding(.horizontal, Theme.Space.lg)
                } else if let err = vm.error {
                    ErrorState(message: err) { Task { await vm.load(id: packageId) } }
                } else if let p = vm.pkg {
                    ScrollView {
                        VStack(alignment: .leading, spacing: Theme.Space.lg) {
                            photo(p)
                            details(p)
                        }
                        .padding(.horizontal, Theme.Space.lg)
                        .padding(.top, Theme.Space.md)
                        .padding(.bottom, Theme.Space.xxl)
                    }
                }
            }
        }
        .navigationTitle("Package")
        .navigationBarTitleDisplayMode(.inline)
        .task { await vm.load(id: packageId) }
    }

    private func photo(_ p: Package) -> some View {
        Color(.secondarySystemBackground)
            .frame(height: 260)
            .overlay {
                if let s = p.photo_url, let url = URL(string: s) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let img): img.resizable().aspectRatio(contentMode: .fill)
                        case .empty: ProgressView()
                        default:
                            Image(systemName: "shippingbox").font(.system(size: 40)).foregroundStyle(Theme.textSecondary)
                        }
                    }
                    .allowsHitTesting(false)
                } else {
                    Image(systemName: "shippingbox").font(.system(size: 40)).foregroundStyle(Theme.textSecondary)
                }
            }
            .clipShape(.rect(cornerRadius: Theme.Radius.lg))
    }

    private func details(_ p: Package) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                HStack {
                    Text(p.carrier ?? "Package")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    StatusPill.package(p.status)
                }
                if let t = p.tracking_number {
                    detailRow("Tracking", t)
                }
                if let r = Fmt.parseDate(p.received_at) {
                    detailRow("Received", Fmt.dateTime(r))
                }
                if let d = Fmt.parseDate(p.picked_up_at) {
                    detailRow("Picked up", Fmt.dateTime(d))
                }
                if let n = p.notes, !n.isEmpty {
                    Divider().background(Theme.divider)
                    Text(n).font(.system(size: 14)).foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            Text(value)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}
