import SwiftUI

struct UsageIcon: View {
    let bundlePath: String?
    var size: CGFloat = 18

    var body: some View {
        if let bundlePath {
            Image(nsImage: IconProvider.icon(forPath: bundlePath, size: size))
                .frame(width: size, height: size)
        } else {
            Image(systemName: "terminal")
                .font(.system(size: size * 0.62, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
        }
    }
}

struct UsageAppLabel: View {
    let usage: AppUsage

    var body: some View {
        HStack(spacing: 6) {
            UsageIcon(bundlePath: usage.bundlePath)
            Text(usage.name)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .accessibilityElement(children: .combine)
    }
}
