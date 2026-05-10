import Foundation
import SwiftUI

enum AuthState: Equatable {
    case loading
    case signedOut
    case nonResidentBlocked
    case bootError(String)
    case signedIn
}

@MainActor
@Observable
final class AppState {
    var authState: AuthState = .loading

    var profile: Profile?
    var units: [Unit] = []
    var roles: [UserRoleRow] = []
    var activeUnitId: String?
    var isBoardMember: Bool = false

    var bootError: String?

    /// Set to a ticket id to request the navigation stack to push the
    /// ticket detail screen. Cleared automatically by the root once consumed.
    var pendingTicketDetailId: String?

    /// Set to a `HomeRoute` to deep-link from a notification tap.
    /// Cleared by `SignedInRoot` once consumed.
    var pendingDeepLink: HomeRoute?

    var activeUnit: Unit? {
        guard let id = activeUnitId else { return units.first }
        return units.first(where: { $0.id == id }) ?? units.first
    }

    var activePropertyId: String? { activeUnit?.property_id }

    func bootstrap() async {
        if SupabaseAPI.shared.isSignedIn {
            await loadAfterAuth()
        } else {
            authState = .signedOut
        }
    }

    func loadAfterAuth() async {
        authState = .loading
        bootError = nil
        do {
            try await SupabaseAPI.shared.refreshIfNeeded()
        } catch {
            // Refresh-token failure → real auth problem, send back to login.
            await SupabaseAPI.shared.signOut()
            authState = .signedOut
            return
        }

        // Load each section independently. A single failure must not sign the user out.
        async let rolesT: [UserRoleRow]? = try? MontyResidentAppService.fetchAllRoles()
        async let profileT: Profile?? = try? MontyResidentAppService.fetchProfile()
        async let unitsT: [Unit]? = try? MontyResidentAppService.fetchUnits()

        let rolesOpt = await rolesT
        let profileOpt = await profileT
        let unitsOpt = await unitsT

        // If everything failed, surface a recoverable error screen.
        if rolesOpt == nil && profileOpt == nil && unitsOpt == nil {
            authState = .bootError("Couldn't reach MontyResidentApp. Check your connection and try again.")
            return
        }

        let roles = rolesOpt ?? []
        let profile = profileOpt ?? nil
        let units = unitsOpt ?? []

        // Hard role gate: any explicit non-resident role blocks access.
        // No role rows + has unit membership → treated as resident (matches web app).
        let hasNonResidentRole = roles.contains { $0.role.lowercased() != "resident" }
        if hasNonResidentRole {
            await SupabaseAPI.shared.signOut()
            self.profile = nil
            self.units = []
            self.roles = []
            self.activeUnitId = nil
            authState = .nonResidentBlocked
            return
        }

        self.roles = roles
        self.profile = profile
        self.units = units

        if let stored = ActiveUnitStore.load(), units.contains(where: { $0.id == stored }) {
            activeUnitId = stored
        } else {
            activeUnitId = units.first?.id
            ActiveUnitStore.save(activeUnitId)
        }

        authState = .signedIn
        await refreshBoardMembership()

        // Re-register the APNs token on every cold start in case it rotated,
        // and pick up any cached token captured before sign-in.
        await NotificationsManager.shared.refreshAuthorizationStatus()
        await NotificationsManager.shared.registerTokenWithBackend()
    }

    func setActiveUnit(_ id: String) {
        activeUnitId = id
        ActiveUnitStore.save(id)
        Task { await refreshBoardMembership() }
    }

    func refreshBoardMembership() async {
        guard let pid = activePropertyId, !pid.isEmpty else {
            isBoardMember = false
            return
        }
        let result = (try? await MontyResidentAppService.fetchIsBoardMember(propertyId: pid)) ?? false
        isBoardMember = result
    }

    func signOut() async {
        await NotificationsManager.shared.revokeToken()
        await SupabaseAPI.shared.signOut()
        profile = nil
        units = []
        roles = []
        activeUnitId = nil
        isBoardMember = false
        authState = .signedOut
    }
}
