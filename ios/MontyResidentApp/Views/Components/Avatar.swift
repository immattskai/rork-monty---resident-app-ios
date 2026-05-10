import SwiftUI

struct Avatar: View {
    let name: String?
    var url: String?
    var size: CGFloat = 40

    private var initials: String {
        let comps = (name ?? "").split(separator: " ").prefix(2)
        let s = comps.compactMap { $0.first.map(String.init) }.joined()
        return s.isEmpty ? "•" : s.uppercased()
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(Theme.divider)
            if let s = url, let u = URL(string: s) {
                AsyncImage(url: u) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable().scaledToFill()
                    default:
                        Text(initials)
                            .font(.system(size: size * 0.38, weight: .medium))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .clipShape(Circle())
            } else {
                Text(initials)
                    .font(.system(size: size * 0.38, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(width: size, height: size)
    }
}
