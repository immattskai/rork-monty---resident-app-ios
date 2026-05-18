//
//  MontyResidentAppApp.swift
//  MontyResidentApp
//

import SwiftUI

@main
struct MontyResidentAppApp: App {
    @UIApplicationDelegateAdaptor(MontyAppDelegate.self) private var appDelegate

    init() {
        // Give URLCache.shared a generous in-memory budget so AsyncImage hits
        // for hero photos, amenities, package photos, post images and avatars
        // don't re-download on every screen visit. (Default in-memory cache is
        // only 512KB which is far too small for image-heavy feeds.)
        URLCache.shared = URLCache(
            memoryCapacity: 64 * 1024 * 1024,       // 64 MB RAM
            diskCapacity:   256 * 1024 * 1024,      // 256 MB disk
            diskPath: "monty-url-cache"
        )

        // Use dynamic UIColors so the chrome follows light/dark automatically.
        let bgDynamic = UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(red: 0x0B/255, green: 0x0C/255, blue: 0x0F/255, alpha: 1)
                : UIColor(red: 0xF4/255, green: 0xF2/255, blue: 0xEC/255, alpha: 1)
        }
        let textDynamic = UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(red: 0xF4/255, green: 0xF4/255, blue: 0xF6/255, alpha: 1)
                : UIColor(red: 0x0B/255, green: 0x0B/255, blue: 0x0C/255, alpha: 1)
        }
        let surfaceDynamic = UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(red: 0x16/255, green: 0x17/255, blue: 0x19/255, alpha: 1)
                : UIColor.white
        }

        let appearance = UINavigationBarAppearance()
        appearance.configureWithTransparentBackground()
        appearance.backgroundColor = bgDynamic
        appearance.shadowColor = .clear
        appearance.titleTextAttributes = [
            .foregroundColor: textDynamic,
            .font: UIFont.systemFont(ofSize: 17, weight: .semibold)
        ]
        appearance.largeTitleTextAttributes = [
            .foregroundColor: textDynamic,
            .font: UIFont.systemFont(ofSize: 32, weight: .semibold)
        ]
        UINavigationBar.appearance().standardAppearance = appearance
        UINavigationBar.appearance().scrollEdgeAppearance = appearance
        UINavigationBar.appearance().compactAppearance = appearance

        let tabAppearance = UITabBarAppearance()
        tabAppearance.configureWithDefaultBackground()
        tabAppearance.backgroundColor = surfaceDynamic
        UITabBar.appearance().standardAppearance = tabAppearance
        UITabBar.appearance().scrollEdgeAppearance = tabAppearance
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
