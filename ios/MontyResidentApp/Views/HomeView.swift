import SwiftUI
import UserNotifications

@MainActor
@Observable
final class HomeViewModel {
    var balance: AccountBalance?
    var openTicketsCount: Int = 0
    var upcomingBookings: [AmenityBooking] = []
    var recentPackages: [Package] = []
    var announcements: [PropertyAnnouncement] = []
    var activeGuestsCount: Int = 0
    var recentPostsCount: Int = 0
    var documentsCount: Int = 0
    var contactsCount: Int = 0

    var loading = true
    var error: String?

    /// Timestamp of the last successful load. Used to skip redundant refetches
    /// when the user bounces back to Home within a short freshness window.
    private var lastLoadedAt: Date?
    private var lastLoadedUnitId: String?
    private let freshnessWindow: TimeInterval = 30

    /// Refetch only the announcements list. Used by the realtime subscription so a
    /// single insert/update doesn't trigger a full home reload.
    func refreshAnnouncements(propertyId: String) async {
        if let anns = try? await AnnouncementsService.fetchActive(propertyId: propertyId, limit: 2) {
            self.announcements = anns
        }
    }

    func load(unitId: String, propertyId: String, unitNumber: String?, force: Bool = false) async {
        // Skip if we just loaded the same unit very recently. Pull-to-refresh
        // passes force=true to bypass this.
        if !force,
           let last = lastLoadedAt,
           lastLoadedUnitId == unitId,
           Date().timeIntervalSince(last) < freshnessWindow {
            loading = false
            return
        }
        loading = true
        error = nil
        async let balanceT: AccountBalance?? = try? MontyResidentAppService.fetchBalance(unitId: unitId)
        async let ticketsT: [Ticket]? = try? MontyResidentAppService.fetchTickets(unitId: unitId, propertyId: propertyId)
        async let bookingsT: [AmenityBooking]? = try? MontyResidentAppService.fetchUpcomingBookings()
        async let packagesT: [Package]? = {
            guard let unitNumber, !unitNumber.isEmpty else { return [] }
            return try? await MontyResidentAppService.fetchPackages(propertyId: propertyId, unitNumber: unitNumber)
        }()
        async let announcementsT: [PropertyAnnouncement]? = try? AnnouncementsService.fetchActive(propertyId: propertyId, limit: 2)
        async let recentCommunityT: [ForumPost]? = try? CommunityService.fetchRecentPosts(propertyId: propertyId, limit: 30)
        async let guestsT: [GuestAccess]? = {
            guard let unitNumber, !unitNumber.isEmpty else { return [] }
            return try? await GuestService.fetchGuests(propertyId: propertyId, unitNumber: unitNumber)
        }()
        async let documentsT: [DocumentItem]? = try? MontyResidentAppService.fetchResidentDocuments(propertyId: propertyId)
        async let contactsT: [StaffContact]? = try? MontyResidentAppService.fetchContacts(propertyId: propertyId)

        let b = await balanceT
        let tickets = await ticketsT ?? []
        let bookings = await bookingsT ?? []
        let packages = await packagesT ?? []
        let anns = await announcementsT ?? []
        let recentCommunity = await recentCommunityT ?? []
        let guests = await guestsT ?? []
        let documents = await documentsT ?? []
        let contacts = await contactsT ?? []

        self.balance = b ?? nil
        self.openTicketsCount = tickets.filter {
            let s = ($0.status ?? "").lowercased()
            return s != "resolved" && s != "closed" && s != "completed"
        }.count
        self.upcomingBookings = bookings
        self.recentPackages = Array(packages.prefix(3))
        self.announcements = anns
        self.activeGuestsCount = guests.filter { $0.isCurrentlyActive }.count
        // "new" = posts in the last 7 days
        let weekAgo = Date().addingTimeInterval(-7 * 24 * 3600)
        self.recentPostsCount = recentCommunity.filter {
            guard let s = $0.created_at, let d = Fmt.parseDate(s) else { return false }
            return d >= weekAgo
        }.count
        self.documentsCount = documents.count
        self.contactsCount = contacts.count
        self.lastLoadedAt = Date()
        self.lastLoadedUnitId = unitId
        loading = false
    }
}

enum HomeRoute: Hashable {
    case profile
    case tickets
    case amenities
    case amenityDetail(Amenity)
    case packages
    case payments
    case documents
    case vendors
    case contacts
    case guests
    case community
    case communityPosts(categoryId: String, categoryName: String)
    case communityPost(postId: String)
    case askMontyResidentApp
    case board
    case notificationSettings
    case announcementsAll
}

struct HomeView: View {
    @Environment(AppState.self) private var app
    @State private var vm = HomeViewModel()
    @State private var notifications = NotificationsManager.shared
    @State private var bannerDismissed: Bool = UserDefaults.standard.bool(forKey: "monty.home.notifBanner.dismissed.v1")

    @State private var selectedAnnouncement: PropertyAnnouncement?
    @State private var announcementsRealtime = AnnouncementsRealtime()
    @State private var inlineMontyInput: String = ""
    @State private var montyChatOpen: Bool = false
    @State private var montyInitialInput: String = ""
    @FocusState private var inlineMontyFocused: Bool
    @Namespace private var montyNS

    private let horizontalPadding: CGFloat = 16

    // Visible hero height after the negative bottom padding (203 - 28).
    private let heroVisibleHeight: CGFloat = 175

    // Mask that keeps the top portion of the ScrollView (which sits behind the
    // sticky row) hidden, then fades content in just below the row.
    private var scrollFadeMask: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: heroVisibleHeight - 24)
            LinearGradient(
                colors: [Color.black.opacity(0), Color.black],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 32)
            Color.black
            // (Mask uses alpha only; color values here don't affect rendering.)
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            AtmosphericBackground()

            // Sticky hero photo + gradient sits BEHIND the scrolling content
            // so cards scroll over it and cleanly cover it.
            heroHeader
                .ignoresSafeArea(edges: .top)
                .allowsHitTesting(false)

            // ScrollView sits BEHIND the sticky row. A mask softly fades the
            // top of the scrolling content so cards appear to magically dissolve
            // just below the building/unit/profile row instead of clipping.
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    // Spacer matching the sticky hero row so cards begin below it.
                    // Small negative offset keeps the top of Ask Monty slightly
                    // overlapping the bottom of the header image.
                    Color.clear
                        .frame(height: heroVisibleHeight - 2)
                        .allowsHitTesting(false)

                    Group {
                        if shouldShowNotificationsBanner {
                            notificationsBanner
                                .padding(.bottom, 8)
                        }

                        askMontyCard
                            .padding(.top, -6)
                            .padding(.bottom, 12)

                        tileGrid

                        bottomQuickRow
                            .padding(.top, 10)

                        announcementsSection
                            .padding(.top, 20)
                    }
                    .padding(.horizontal, horizontalPadding)
                }
                .padding(.bottom, 40)
            }
            .ignoresSafeArea(edges: .top)
            .scrollBounceBehavior(.basedOnSize)
            .scrollDisabled(true)
            .refreshable { await reload(force: true) }
            .mask(scrollFadeMask.ignoresSafeArea())

            // Sticky building name + unit + profile row sits ON TOP so it stays
            // crisp and fully tappable while cards fade away beneath it.
            heroForeground
                .frame(height: heroVisibleHeight, alignment: .top)
                .ignoresSafeArea(edges: .top)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(for: String.self) { id in
            TicketDetailView(ticketId: id)
        }
        .navigationDestination(for: HomeRoute.self) { route in
            switch route {
            case .profile: ProfileView()
            case .tickets: TicketsListView()
            case .amenities: AmenitiesView()
            case .amenityDetail(let a): AmenityDetailView(amenity: a)
            case .packages: PackagesListView()
            case .payments: PaymentsView()
            case .documents: DocumentsView()
            case .vendors: VendorsView()
            case .contacts: ContactsView()
            case .guests: GuestsView()
            case .community: CommunityCategoriesView()
            case .communityPosts(let id, let name): CommunityPostsView(categoryId: id, categoryName: name)
            case .communityPost(let id): CommunityPostDetailView(postId: id)
            case .askMontyResidentApp: MontyChatView()
                    .navigationTransition(.zoom(sourceID: "monty", in: montyNS))
            case .board: BoardView()
            case .notificationSettings: NotificationSettingsView()
            case .announcementsAll: AnnouncementsListView()
            }
        }
        .navigationDestination(isPresented: $montyChatOpen) {
            MontyChatView(initialInput: montyInitialInput)
                .navigationTransition(.zoom(sourceID: "monty", in: montyNS))
        }
        .sheet(item: $selectedAnnouncement) { ann in
            AnnouncementDetailSheet(announcement: ann)
        }
        .task(id: app.activeUnitId) {
            await reload()
        }
        .task(id: app.activeUnit?.property_id) {
            await subscribeAnnouncements()
        }
        .task {
            await notifications.refreshAuthorizationStatus()
        }
    }

    private func subscribeAnnouncements() async {
        announcementsRealtime.stop()
        guard
            let propertyId = app.activeUnit?.property_id,
            let token = SupabaseAPI.shared.session?.access_token
        else { return }
        announcementsRealtime.onChange = {
            Task { @MainActor in
                await vm.refreshAnnouncements(propertyId: propertyId)
            }
        }
        announcementsRealtime.start(propertyId: propertyId, accessToken: token)
    }

    private func reload(force: Bool = false) async {
        guard let unit = app.activeUnit else {
            vm.loading = false
            return
        }
        await vm.load(unitId: unit.id, propertyId: unit.property_id, unitNumber: unit.unit_number, force: force)
    }

    private var initials: String {
        let n = app.profile?.full_name ?? ""
        let parts = n.split(separator: " ").prefix(2)
        let s = parts.compactMap { $0.first.map(String.init) }.joined().uppercased()
        return s.isEmpty ? "" : s
    }

    // MARK: - Notifications banner

    private var shouldShowNotificationsBanner: Bool {
        guard !bannerDismissed else { return false }
        switch notifications.authorizationStatus {
        case .denied: return true
        case .notDetermined: return notifications.hasShownSoftAsk
        default: return false
        }
    }

    private var notificationsBanner: some View {
        NavigationLink(value: HomeRoute.notificationSettings) {
            ZStack(alignment: .leading) {
                premiumCardBackground(radius: 18)

                // Orange left-edge accent gradient.
                LinearGradient(
                    colors: [Color(hex: 0xFFB15E), Color(hex: 0xFF6A00)],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(width: 2)
                .clipShape(.rect(cornerRadius: 1))
                .padding(.vertical, 10)

                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color(hex: 0xFF8A1F).opacity(0.10))
                        Image(systemName: "bell")
                            .font(.system(size: 18, weight: .regular))
                            .foregroundStyle(Color(hex: 0xFF8A1F))
                    }
                    .frame(width: 42, height: 42)

                    Text("Tap here to enable notifications for packages and tickets.")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color.chrome(0.66))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Button {
                        bannerDismissed = true
                        UserDefaults.standard.set(true, forKey: "monty.home.notifBanner.dismissed.v1")
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.chrome(0.45))
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.leading, 14)
                .padding(.trailing, 6)
            }
            .frame(height: 72)
        }
        .buttonStyle(PressableCardStyle())
    }

    // MARK: - Hero

    private var heroHeader: some View {
        let property = app.activeUnit?.property
        let heroURL = property?.heroPhotoURL
        let buildingName = (property?.name).flatMap { $0.isEmpty ? nil : $0 } ?? "Home"
        let unitNumber = app.activeUnit?.unit_number ?? ""

        return Theme.heroBase
            .frame(height: 203)
            .overlay {
                Group {
                    if let heroURL {
                        AsyncImage(url: heroURL) { phase in
                            switch phase {
                            case .success(let img):
                                img.resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .brightness(-0.10)
                                    .saturation(0.90)
                                    .contrast(1.06)
                            default:
                                heroFallbackGradient
                            }
                        }
                    } else {
                        heroFallbackGradient
                    }
                }
                .frame(height: 203)
                .clipped()
                .allowsHitTesting(false)
            }
            .overlay {
                ZStack {
                    // Radial wash anchored to the lower-left — black in dark mode,
                    // soft page-color in light mode so the photo melts into the page.
                    RadialGradient(
                        colors: [
                            Color.chromeInverse(0.92),
                            Color.chromeInverse(0.55),
                            Color.chromeInverse(0.0)
                        ],
                        center: .init(x: 0.05, y: 0.85),
                        startRadius: 20,
                        endRadius: 520
                    )
                    // Subtle navy sky tint over the top (dark only).
                    LinearGradient(
                        colors: [
                            Color(red: 0.04, green: 0.08, blue: 0.20).opacity(0.55),
                            Color.clear
                        ],
                        startPoint: .top, endPoint: .center
                    )
                    .blendMode(.overlay)
                    // Bottom fade into the page background for a seamless edge.
                    // Uses the actual page background color in light mode so the
                    // photo melts into the cream parchment (not pure white).
                    LinearGradient(
                        stops: [
                            .init(color: Theme.background.opacity(0.0), location: 0.30),
                            .init(color: Theme.background.opacity(0.45), location: 0.55),
                            .init(color: Theme.background.opacity(0.80), location: 0.78),
                            .init(color: Theme.background.opacity(0.97), location: 0.94),
                            .init(color: Theme.background, location: 1.0)
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                }
                .allowsHitTesting(false)
            }
            .clipShape(.rect)
            .padding(.bottom, -28)
    }

    // Foreground row that scrolls with the page (building name, resident · unit, profile).
    private var heroForeground: some View {
        let property = app.activeUnit?.property
        let buildingName = (property?.name).flatMap { $0.isEmpty ? nil : $0 } ?? "Home"
        let unitNumber = app.activeUnit?.unit_number ?? ""

        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(buildingName)
                    .font(.system(size: 27, weight: .bold))
                    .tracking(-0.6)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .shadow(color: Color.chromeInverse(0.6), radius: 6, y: 1)

                HStack(spacing: 5) {
                    Text(displayName)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                    if !unitNumber.isEmpty {
                        Text("\u{00B7}")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Theme.textMuted)
                        Text(unitNumber)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Theme.textMuted)
                }
                .shadow(color: Color.chromeInverse(0.5), radius: 4, y: 1)
            }
            .padding(.leading, 4)

            Spacer(minLength: 0)

            NavigationLink(value: HomeRoute.profile) {
                ZStack {
                    Circle().fill(Color.chrome(0.08))
                    Circle().stroke(Color.chrome(0.18), lineWidth: 0.8)
                    Text(initials)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                }
                .frame(width: 32, height: 32)
                .shadow(color: Color.chromeInverse(0.5), radius: 5, y: 1)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.top, 66)
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private var heroFallbackGradient: some View {
        LinearGradient(
            colors: [Color(hex: 0x172238), Color(hex: 0x080B14)],
            startPoint: .top, endPoint: .bottom
        )
    }

    private var displayName: String {
        let n = app.profile?.full_name ?? ""
        return n.isEmpty ? "Welcome" : n.split(separator: " ").first.map(String.init) ?? n
    }

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        switch h {
        case 5..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        case 17..<22: return "Good evening"
        default: return "Welcome home"
        }
    }

    // MARK: - Ask Monty

    private var askMontyCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button {
                openMonty(with: "")
            } label: {
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Ask Monty")
                            .font(.system(size: 21, weight: .bold))
                            .tracking(-0.4)
                            .foregroundStyle(Theme.textPrimary)
                        Text("Get instant answers about building policies, submit requests, and more.")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.chrome(0.58))
                            .lineSpacing(1)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            HStack(spacing: 8) {
                TextField(
                    "",
                    text: $inlineMontyInput,
                    prompt: Text("Ask Monty anything\u{2026}")
                        .foregroundStyle(Color.chrome(0.36))
                )
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundStyle(Theme.textPrimary)
                .focused($inlineMontyFocused)
                .submitLabel(.send)
                .onSubmit { submitInline() }

                Button {
                    submitInline()
                } label: {
                    ZStack {
                        Circle().fill(
                            LinearGradient(
                                colors: [Color(hex: 0xFFB15E), Color(hex: 0xFF6A00)],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            )
                        )
                        .opacity(canSendInline ? 1 : 0.55)
                        Image(systemName: "arrow.up")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 30, height: 30)
                    .shadow(color: Color(hex: 0xFF6A00).opacity(canSendInline ? 0.45 : 0), radius: 10, y: 3)
                }
                .buttonStyle(.plain)
                .animation(.easeOut(duration: 0.18), value: canSendInline)
            }
            .padding(.leading, 14)
            .padding(.trailing, 5)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.chrome(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.chrome(0.08), lineWidth: 0.5)
            )
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Theme.premiumDark)
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color.chrome(0.06), lineWidth: 0.6)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(alignment: .topTrailing) {
            Image(systemName: "sparkles")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color(hex: 0xFFB15E), Color(hex: 0xFF6A00)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
                .padding(.top, 14)
                .padding(.trailing, 16)
                .allowsHitTesting(false)
        }
        .shadow(color: Theme.cardDropShadow, radius: 18, x: 0, y: 8)
        .matchedTransitionSource(id: "monty", in: montyNS)
    }

    private var canSendInline: Bool {
        !inlineMontyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submitInline() {
        let text = inlineMontyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        openMonty(with: text)
    }

    private func openMonty(with text: String) {
        Haptics.tap()
        montyInitialInput = text
        inlineMontyFocused = false
        // Clear the inline field so it's empty when the user returns.
        if !text.isEmpty { inlineMontyInput = "" }
        montyChatOpen = true
    }

    // MARK: - Premium card background helper

    @ViewBuilder
    private func premiumCardBackground(radius: CGFloat) -> some View {
        let r = max(radius - 4, 8)
        return ZStack {
            RoundedRectangle(cornerRadius: r, style: .continuous)
                .fill(Theme.premiumDark)
            RoundedRectangle(cornerRadius: r, style: .continuous)
                .stroke(Color.chrome(0.06), lineWidth: 0.6)
        }
    }

    // MARK: - Board

    // MARK: - Tile grid

    private struct Tile {
        let title: String
        let icon: String
        let route: HomeRoute
        var metric: String
        var metricAccent: TileAccent = .neutral
        var iconAccent: TileAccent = .muted
        var emphasis: TileEmphasis = .standard
        var trailing: Trailing = .chevron
    }

    private enum Trailing { case chevron, check }
    private enum TileEmphasis { case strong, standard, quiet }
    private enum TileAccent {
        case neutral, blue, amber, orange, muted
        var color: Color {
            switch self {
            case .neutral: return Color.chrome(0.52)
            case .blue:    return Theme.accentBlue
            case .amber:   return Theme.accentAmber
            case .orange:  return Color(hex: 0xFF9A2F)
            case .muted:   return Color(hex: 0x8DA0B8)
            }
        }
    }

    /// Two left-column tiles paired with the tall Payments card (same height each).
    private var leftColumnTiles: [Tile] {
        let openTickets = vm.openTicketsCount
        let pkgPending = vm.recentPackages.filter { $0.isPending }.count

        return [
            Tile(title: "Tickets", icon: "wrench.and.screwdriver",
                 route: .tickets,
                 metric: openTickets > 0 ? "\(openTickets) open" : "All clear",
                 metricAccent: openTickets > 0 ? .orange : .neutral,
                 iconAccent: .orange,
                 emphasis: .strong),
            Tile(title: "Packages", icon: "shippingbox",
                 route: .packages,
                 metric: pkgPending > 0 ? "\(pkgPending) waiting" : "None waiting",
                 metricAccent: pkgPending > 0 ? .blue : .neutral,
                 iconAccent: pkgPending > 0 ? .blue : .muted,
                 emphasis: .standard),
        ]
    }

    private var guestsTile: Tile {
        Tile(title: "Guests", icon: "person.crop.circle.badge.checkmark",
             route: .guests,
             metric: vm.activeGuestsCount > 0 ? "\(vm.activeGuestsCount) active" : "None active",
             metricAccent: vm.activeGuestsCount > 0 ? .blue : .neutral,
             iconAccent: .muted,
             emphasis: .quiet)
    }

    private var communityTile: Tile {
        Tile(title: "Community", icon: "person.2",
             route: .community,
             metric: vm.recentPostsCount > 0 ? "\(vm.recentPostsCount) new this week" : "No new posts",
             iconAccent: .muted,
             emphasis: .standard)
    }

    private var boardTile: Tile {
        Tile(title: "Board", icon: "building.columns",
             route: .board,
             metric: "Board portal",
             metricAccent: .blue,
             iconAccent: .blue,
             emphasis: .standard)
    }

    private func iconBackgroundFill(for tile: Tile) -> Color {
        switch tile.iconAccent {
        case .orange: return Color(hex: 0xFF9A2F).opacity(0.12)
        case .amber:  return Theme.accentAmber.opacity(0.12)
        case .blue:   return Theme.accentBlue.opacity(0.10)
        default:      return Color.chrome(tile.emphasis == .quiet ? 0.03 : 0.05)
        }
    }

    private func paymentsDueText(cents: Int) -> String {
        Fmt.currencyWhole(cents: cents) + " due"
    }

    private static let homeTileHeight: CGFloat = 68
    private static let homeTileSpacing: CGFloat = 10

    private var tileGrid: some View {
        VStack(spacing: Self.homeTileSpacing) {
            HStack(alignment: .top, spacing: Self.homeTileSpacing) {
                // Left column — Tickets + Packages stacked
                VStack(spacing: Self.homeTileSpacing) {
                    ForEach(Array(leftColumnTiles.enumerated()), id: \.offset) { _, tile in
                        tileLink(for: tile)
                    }
                }
                .frame(maxWidth: .infinity)

                // Right — tall Payments card matching height of the two left tiles
                paymentsTallCard
                    .frame(maxWidth: .infinity)
                    .frame(height: Self.homeTileHeight * 2 + Self.homeTileSpacing)
            }

            // Bottom row of the grid: Guests + Community (+ Board if member)
            HStack(alignment: .top, spacing: Self.homeTileSpacing) {
                let compact = app.isBoardMember
                tileLink(for: guestsTile, compact: compact)
                tileLink(for: communityTile, compact: compact)
                if app.isBoardMember {
                    tileLink(for: boardTile, compact: compact)
                }
            }
        }
    }

    @ViewBuilder
    private func tileLink(for tile: Tile, fullWidth: Bool = false, compact: Bool = false) -> some View {
        let iconBox: CGFloat = compact ? 28 : 36
        let iconSize: CGFloat = compact ? 13 : 16
        let titleSize: CGFloat = compact ? 13 : 15
        let metricSize: CGFloat = compact ? 10.5 : 11.5
        let hSpacing: CGFloat = compact ? 7 : 10
        let hPad: CGFloat = compact ? 9 : 12

        NavigationLink(value: tile.route) {
            ZStack {
                premiumCardBackground(radius: 16)
                HStack(spacing: hSpacing) {
                    ZStack {
                        RoundedRectangle(cornerRadius: compact ? 9 : 11, style: .continuous)
                            .fill(iconBackgroundFill(for: tile))
                        Image(systemName: tile.icon)
                            .font(.system(size: iconSize, weight: tile.emphasis == .strong ? .semibold : .regular))
                            .foregroundStyle(tile.iconAccent.color.opacity(tile.emphasis == .quiet ? 0.78 : 1))
                    }
                    .frame(width: iconBox, height: iconBox)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(tile.title)
                            .font(.system(size: titleSize, weight: tile.emphasis == .strong ? .bold : .semibold))
                            .tracking(-0.2)
                            .foregroundStyle(Color.chrome(tile.emphasis == .quiet ? 0.82 : 1))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Text(tile.metric)
                            .font(.system(size: metricSize, weight: .medium))
                            .foregroundStyle(tile.metricAccent == .neutral ? Color.chrome(tile.emphasis == .quiet ? 0.50 : 0.62) : tile.metricAccent.color)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    Spacer(minLength: 2)

                    if case .check = tile.trailing {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 18, weight: .regular))
                            .foregroundStyle(Color(hex: 0x4DA3FF))
                    }
                }
                .padding(.horizontal, hPad)
                .padding(.vertical, 10)
            }
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .frame(height: Self.homeTileHeight)
            .shadow(color: Theme.cardDropShadow, radius: 14, x: 0, y: 6)
        }
        .buttonStyle(PressableCardStyle())
        .simultaneousGesture(TapGesture().onEnded {
            Haptics.tap()
        })
    }

    // MARK: - Tall Payments card

    private var paymentsTallCard: some View {
        let balanceCents = vm.balance?.balance_cents ?? 0
        let paid = balanceCents <= 0
        let accent: Color = paid ? Theme.accentBlue : Theme.accentAmber
        let amountText: String = paid ? "No balance" : Self.currencyString(cents: balanceCents)
        let captionText: String = paid ? "You're all caught up" : "Current balance"

        return NavigationLink(value: HomeRoute.payments) {
            ZStack {
                premiumCardBackground(radius: 18)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(accent.opacity(0.12))
                            Image(systemName: paid ? "checkmark.seal.fill" : "creditcard")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(accent)
                        }
                        .frame(width: 40, height: 40)

                        Spacer(minLength: 4)
                    }

                    Spacer(minLength: 0)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Payments")
                            .font(.system(size: 13, weight: .semibold))
                            .tracking(-0.1)
                            .foregroundStyle(Color.chrome(0.62))
                        Text(amountText)
                            .font(.system(size: paid ? 30 : 40, weight: .bold))
                            .tracking(-0.8)
                            .foregroundStyle(Color.chrome(1))
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                        if !paid {
                            Text(captionText)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Color.chrome(0.55))
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .shadow(color: Theme.cardDropShadow, radius: 14, x: 0, y: 6)
        }
        .buttonStyle(PressableCardStyle())
        .simultaneousGesture(TapGesture().onEnded {
            Haptics.tap()
        })
    }

    private static func currencyString(cents: Int) -> String {
        Fmt.currencyWhole(cents: cents)
    }

    // MARK: - Bottom quick row (Documents / Vendors / Contacts)

    private struct QuickItem: Identifiable {
        let id = UUID()
        let title: String
        let icon: String
        let route: HomeRoute
    }

    private var bottomQuickRow: some View {
        let items: [QuickItem] = [
            QuickItem(title: "Documents", icon: "doc.text", route: .documents),
            QuickItem(title: "Vendors", icon: "hammer", route: .vendors),
            QuickItem(title: "Contacts", icon: "phone", route: .contacts),
            QuickItem(title: "Amenities", icon: "calendar", route: .amenities),
        ]
        return HStack(spacing: 8) {
            ForEach(items) { item in
                NavigationLink(value: item.route) {
                    ZStack {
                        premiumCardBackground(radius: 16)
                        HStack(spacing: 6) {
                            Image(systemName: item.icon)
                                .font(.system(size: 13, weight: .regular))
                                .foregroundStyle(Color(hex: 0x8DA0B8).opacity(0.92))
                            Text(item.title)
                                .font(.system(size: 11.5, weight: .semibold))
                                .tracking(-0.2)
                                .foregroundStyle(Color.chrome(0.82))
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 6)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: Self.homeTileHeight)
                    .shadow(color: Theme.cardDropShadow, radius: 14, x: 0, y: 6)
                }
                .buttonStyle(PressableCardStyle())
                .simultaneousGesture(TapGesture().onEnded {
                    Haptics.tap()
                })
            }
        }
    }

    // MARK: - Building announcements

    @ViewBuilder
    private var announcementsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("ANNOUNCEMENTS")
                .font(.system(size: 12, weight: .heavy))
                .tracking(1.4)
                .foregroundStyle(Color.chrome(0.55))
                .padding(.horizontal, 4)

            if vm.announcements.isEmpty {
                emptyAnnouncements
            } else {
                VStack(spacing: 10) {
                    ForEach(vm.announcements.prefix(2), id: \.id) { ann in
                        featuredAnnouncement(ann)
                    }
                }
            }

            HStack {
                Spacer()
                NavigationLink(value: HomeRoute.announcementsAll) {
                    HStack(spacing: 6) {
                        Text("View all announcements")
                            .font(.system(size: 12.5, weight: .semibold))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .foregroundStyle(Color.chrome(0.85))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.chrome(0.06))
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(Color.chrome(0.10), lineWidth: 0.6)
                    )
                }
                .simultaneousGesture(TapGesture().onEnded {
                    Haptics.tap()
                })
                Spacer()
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyAnnouncements: some View {
        ZStack {
            premiumCardBackground(radius: 18)
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.chrome(0.04))
                        .frame(width: 40, height: 40)
                    Image(systemName: "megaphone")
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(Color.chrome(0.55))
                }
                Text("No announcements right now")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.chrome(0.55))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
        }
        .frame(height: 64)
    }

    private func featuredAnnouncement(_ ann: PropertyAnnouncement) -> some View {
        Button {
            selectedAnnouncement = ann
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Theme.premiumDark)
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.chrome(0.06), lineWidth: 0.6)

                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(ann.title ?? "Building announcement")
                            .font(.system(size: 14.5, weight: .bold))
                            .tracking(-0.2)
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                            .padding(.trailing, ann.isPinned ? 22 : 0)
                        HStack(spacing: 6) {
                            if let body = ann.body, !body.isEmpty {
                                Text(body)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(Color.chrome(0.55))
                                    .lineLimit(1)
                            }
                            if ann.body != nil && ann.publishedDate != nil {
                                Circle()
                                    .fill(Color.chrome(0.30))
                                    .frame(width: 2.5, height: 2.5)
                            }
                            if let d = ann.publishedDate {
                                Text(Fmt.relative(d))
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundStyle(Color.chrome(0.45))
                                    .lineLimit(1)
                            }
                        }
                    }
                    Spacer(minLength: 8)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
            }
            .clipShape(.rect(cornerRadius: 14))
            .overlay(alignment: .topTrailing) {
                if ann.isPinned { pinnedBadge.padding(10) }
            }
            .shadow(color: Theme.cardDropShadow, radius: 14, x: 0, y: 5)
        }
        .buttonStyle(PressableCardStyle())
    }

    private var pinnedBadge: some View {
        Image(systemName: "pin.fill")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(Color(hex: 0xE7C27A))
            .rotationEffect(.degrees(45))
            .frame(width: 22, height: 22)
            .background(Circle().fill(Color(hex: 0xE7C27A).opacity(0.12)))
            .overlay(Circle().stroke(Color(hex: 0xE7C27A).opacity(0.30), lineWidth: 0.5))
    }

    private func listAnnouncement(_ ann: PropertyAnnouncement) -> some View {
        Button {
            selectedAnnouncement = ann
        } label: {
            ZStack {
                premiumCardBackground(radius: 18)
                HStack(alignment: .center, spacing: 14) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(ann.title ?? "Announcement")
                            .font(.system(size: 16, weight: .bold))
                            .tracking(-0.2)
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                            .padding(.trailing, ann.isPinned ? 22 : 0)
                        if let body = ann.body, !body.isEmpty {
                            Text(body)
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(Color.chrome(0.58))
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                                .lineSpacing(1)
                        }
                        if let d = ann.publishedDate {
                            Text(Fmt.relative(d))
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Color.chrome(0.40))
                        }
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.chrome(0.36))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .clipShape(.rect(cornerRadius: 16))
            .overlay(alignment: .topTrailing) {
                if ann.isPinned { pinnedBadge.padding(10) }
            }
            .shadow(color: Theme.cardDropShadow, radius: 14, x: 0, y: 5)
        }
        .buttonStyle(PressableCardStyle())
    }
}

// MARK: - Announcement detail sheet

struct AnnouncementDetailSheet: View {
    let announcement: PropertyAnnouncement
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top, spacing: 12) {
                        Text(announcement.title ?? "Announcement")
                            .font(.system(size: 24, weight: .bold))
                            .tracking(-0.4)
                            .foregroundStyle(Theme.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if announcement.isPinned {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(Color(hex: 0xE7C27A))
                                .rotationEffect(.degrees(45))
                                .frame(width: 28, height: 28)
                                .background(Circle().fill(Color(hex: 0xE7C27A).opacity(0.12)))
                                .overlay(Circle().stroke(Color(hex: 0xE7C27A).opacity(0.30), lineWidth: 0.5))
                        }
                    }

                    if let d = announcement.publishedDate {
                        Text(Fmt.relative(d))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.chrome(0.50))
                    }

                    if let body = announcement.body, !body.isEmpty {
                        Text(body)
                            .font(.system(size: 15.5, weight: .regular))
                            .foregroundStyle(Color.chrome(0.85))
                            .lineSpacing(4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 32)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(AtmosphericBackground().ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Theme.textPrimary)
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(Color.chrome(0.10)))
                    }
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationContentInteraction(.scrolls)
    }
}

// MARK: - Pressable card style

struct PressableCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .opacity(configuration.isPressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.18), value: configuration.isPressed)
    }
}

struct ComingSoonView: View {
    let title: String
    let icon: String
    let blurb: String

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 16) {
                ZStack {
                    Circle().fill(Theme.surface)
                    Image(systemName: icon)
                        .font(.system(size: 24, weight: .light))
                        .foregroundStyle(Theme.textPrimary)
                }
                .frame(width: 72, height: 72)
                .overlay(Circle().stroke(Theme.border, lineWidth: 0.5))
                Text(title)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(blurb)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
