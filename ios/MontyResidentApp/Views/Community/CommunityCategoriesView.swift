import SwiftUI
import UIKit

@MainActor
@Observable
final class CommunityCategoriesViewModel {
    var rules: [ForumRule] = []
    var categories: [ForumCategory] = []
    var counts: [String: Int] = [:]
    var loading = true
    var error: String?

    func load(propertyId: String) async {
        loading = true
        error = nil
        async let rulesT: [ForumRule]? = try? CommunityService.fetchRules(propertyId: propertyId)
        async let catsT: [ForumCategory]? = try? CommunityService.fetchCategories(propertyId: propertyId)
        let r = await rulesT ?? []
        let c = await catsT ?? []
        self.rules = r.sorted { ($0.sort_order ?? 0) < ($1.sort_order ?? 0) }
        self.categories = c.sorted { ($0.sort_order ?? 0) < ($1.sort_order ?? 0) }
        if !self.categories.isEmpty {
            self.counts = (try? await CommunityService.fetchPostCounts(
                propertyId: propertyId,
                categoryIds: self.categories.map(\.id)
            )) ?? [:]
        } else {
            self.counts = [:]
        }
        loading = false
    }
}

struct CommunityCategoriesView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var vm = CommunityCategoriesViewModel()
    @State private var rulesExpanded = false

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
        if vm.loading && vm.categories.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    header
                    ForEach(0..<5, id: \.self) { _ in skeletonRow }
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.top, 8)
            }
        } else if let err = vm.error {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    ZStack {
                        premiumCardBackground(radius: 18)
                        ErrorState(message: err) { Task { await reload() } }
                            .padding(.vertical, 8)
                    }
                    .clipShape(.rect(cornerRadius: 18))
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.top, 8)
            }
            .refreshable { await reload() }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    header

                    if !vm.rules.isEmpty {
                        rulesCard
                    }

                    if vm.categories.isEmpty {
                        emptyState
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            sectionHeader("DISCUSSION BOARDS")
                            categoriesList
                        }
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
                Text("Community")
                    .font(.system(size: 30, weight: .bold))
                    .tracking(-0.6)
                    .foregroundStyle(Theme.textPrimary)
                Text(subline)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.chrome(0.55))
            }
        }
        .padding(.top, 4)
        .padding(.bottom, 4)
    }

    private var subline: String {
        if let p = app.activeUnit?.property?.name, !p.isEmpty {
            return p
        }
        return "Conversations from your building"
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

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .heavy))
            .tracking(1.2)
            .foregroundStyle(Color.chrome(0.45))
            .padding(.top, 4)
    }

    // MARK: - Rules

    private var rulesCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                    rulesExpanded.toggle()
                }
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color(hex: 0x6FA8E0).opacity(0.14))
                        Image(systemName: "list.bullet.rectangle")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color(hex: 0x6FA8E0))
                    }
                    .frame(width: 32, height: 32)
                    Text("Community rules")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Text("\(vm.rules.count)")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.chrome(0.5))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.chrome(0.55))
                        .rotationEffect(.degrees(rulesExpanded ? 180 : 0))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if rulesExpanded {
                Divider().background(Color.chrome(0.06))
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(vm.rules.enumerated()), id: \.element.id) { idx, rule in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text("\(idx + 1)")
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Color.chrome(0.45))
                                .frame(width: 16, alignment: .leading)
                            Text(rule.content ?? "")
                                .font(.system(size: 14))
                                .foregroundStyle(Color.chrome(0.85))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
            }
        }
        .background(premiumCardBackground(radius: 16))
        .clipShape(.rect(cornerRadius: 16))
        .shadow(color: Theme.cardDropShadow, radius: 12, x: 0, y: 4)
    }

    // MARK: - Categories

    private var categoriesList: some View {
        VStack(spacing: 10) {
            ForEach(vm.categories) { cat in
                NavigationLink(value: HomeRoute.communityPosts(categoryId: cat.id, categoryName: cat.name ?? "Category")) {
                    categoryRow(cat)
                }
                .buttonStyle(PressableCardStyle())
                .simultaneousGesture(TapGesture().onEnded {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                })
            }
        }
    }

    private func categoryRow(_ cat: ForumCategory) -> some View {
        let count = vm.counts[cat.id] ?? 0
        return ZStack {
            premiumCardBackground(radius: 16)
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.chrome(0.05))
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.chrome(0.7))
                }
                .frame(width: 42, height: 42)
                .padding(.top, 1)

                VStack(alignment: .leading, spacing: 4) {
                    Text(cat.name ?? "Category")
                        .font(.system(size: 15.5, weight: .semibold))
                        .tracking(-0.2)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    if let d = cat.description, !d.isEmpty {
                        Text(d)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(Color.chrome(0.55))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .trailing, spacing: 8) {
                    HStack(spacing: 4) {
                        Image(systemName: "bubble.right")
                            .font(.system(size: 10, weight: .semibold))
                        Text("\(count)")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                    }
                    .foregroundStyle(Color.chrome(0.55))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.chrome(0.06)))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.chrome(0.32))
                }
                .padding(.top, 2)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
        }
        .clipShape(.rect(cornerRadius: 16))
        .shadow(color: Theme.cardDropShadow, radius: 14, x: 0, y: 6)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        ZStack {
            premiumCardBackground(radius: 18)
            VStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.chrome(0.04))
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(Color.chrome(0.62))
                }
                .frame(width: 56, height: 56)
                Text("No discussion boards yet")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Your building's community space hasn't been set up yet.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.chrome(0.55))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
            }
            .padding(.vertical, 28)
            .padding(.horizontal, 22)
            .frame(maxWidth: .infinity)
        }
        .clipShape(.rect(cornerRadius: 18))
        .padding(.top, 12)
    }

    // MARK: - Skeleton

    private var skeletonRow: some View {
        ZStack {
            premiumCardBackground(radius: 16)
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 12).fill(Color.chrome(0.05))
                    .frame(width: 42, height: 42)
                VStack(alignment: .leading, spacing: 8) {
                    RoundedRectangle(cornerRadius: 4).fill(Color.chrome(0.08))
                        .frame(height: 12).frame(maxWidth: 160, alignment: .leading)
                    RoundedRectangle(cornerRadius: 4).fill(Color.chrome(0.05))
                        .frame(height: 10).frame(maxWidth: 220, alignment: .leading)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
        }
        .frame(height: 78)
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
        guard let pid = app.activePropertyId else {
            vm.loading = false
            return
        }
        await vm.load(propertyId: pid)
    }
}

// Lightweight pressable style that highlights row background instead of scaling
struct PressableHighlightStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color.chrome(0.04) : Color.clear)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
