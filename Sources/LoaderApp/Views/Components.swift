import SwiftUI

/// Color-coded latency badge shared by the menu and the servers sheet.
struct PingBadge: View {
    let result: PingResult?

    var body: some View {
        switch result {
        case .measuring:
            ProgressView().controlSize(.mini)
        case .ms(let v):
            Text("\(v) ms")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(color(v))
        case .failed:
            Text("—").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.danger)
        case nil:
            EmptyView()
        }
    }

    private func color(_ v: Int) -> Color {
        v < 100 ? Theme.accent : (v < 250 ? Theme.warn : Theme.danger)
    }
}
