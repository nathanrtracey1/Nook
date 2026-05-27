import SwiftUI

struct CanopyShieldBadge: View {
    @ObservedObject private var stats = CanopyStatsManager.shared

    var body: some View {
        if stats.sessionBlockCount > 0 {
            HStack(spacing: 4) {
                Image(systemName: "shield.checkered")
                    .font(.system(size: 10, weight: .semibold))
                Text(stats.formattedSessionCount)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
            }
            .foregroundStyle(.green)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.green.opacity(0.12))
            .clipShape(Capsule())
            .help("Canopy blocked \(stats.sessionBlockCount) request\(stats.sessionBlockCount == 1 ? "" : "s") this session (\(stats.formattedTotalCount) total)")
        }
    }
}
