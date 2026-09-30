//
// Components.swift
// MacMonitor
// 卡片、迷你曲线、进度条等通用界面组件与格式化工具。
//

import SwiftUI

struct Card<Content: View>: View {
    let title: String
    let symbol: String
    var value: String?
    var valueColor: Color = .primary
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Label(title, systemImage: symbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let value {
                    Text(value)
                        .font(.system(.title3, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(valueColor)
                }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }
}

/// 固定长度的滚动曲线, 新数据从右侧进入
struct Sparkline: View {
    let values: [Double]
    /// 纵轴上限; nil 时按当前窗口最大值自适应
    var ceiling: Double?
    var color: Color = .accentColor

    var body: some View {
        GeometryReader { geo in
            let peak = Swift.max(ceiling ?? (values.max() ?? 1) * 1.15, 0.0001)
            let step = geo.size.width / CGFloat(Monitor.historyLength - 1)
            let points = values.enumerated().map { i, v in
                CGPoint(x: geo.size.width - CGFloat(values.count - 1 - i) * step,
                        y: geo.size.height * (1 - CGFloat(Swift.min(v / peak, 1))))
            }
            ZStack {
                if let first = points.first, let last = points.last {
                    Path { p in
                        p.move(to: CGPoint(x: first.x, y: geo.size.height))
                        points.forEach { p.addLine(to: $0) }
                        p.addLine(to: CGPoint(x: last.x, y: geo.size.height))
                        p.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [color.opacity(0.35), color.opacity(0.02)],
                                         startPoint: .top, endPoint: .bottom))
                    Path { p in p.addLines(points) }
                        .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                }
            }
        }
    }
}

struct Bar: View {
    let value: Double
    var color: Color = .accentColor
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.1))
                Capsule().fill(color)
                    .frame(width: geo.size.width * CGFloat(Swift.min(Swift.max(value, 0), 1)))
            }
        }
        .frame(height: height)
    }
}

/// 每个逻辑核一根竖条
struct CoreBars: View {
    let cores: [Double]

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(Array(cores.enumerated()), id: \.offset) { _, v in
                GeometryReader { geo in
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Format.loadColor(v))
                            .frame(height: Swift.max(geo.size.height * CGFloat(v), 1.5))
                    }
                }
                .background(RoundedRectangle(cornerRadius: 1.5).fill(.primary.opacity(0.08)))
            }
        }
        .frame(height: 22)
    }
}

struct InfoRow: View {
    let label: String
    let value: String
    var color: Color = .primary

    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit().foregroundStyle(color)
        }
        .font(.caption)
    }
}

enum Format {
    static func percent(_ v: Double) -> String {
        "\(Int((v * 100).rounded()))%"
    }

    static func bytes(_ b: UInt64) -> String {
        let gb = Double(b) / 1_073_741_824
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        return String(format: "%.0f MB", Double(b) / 1_048_576)
    }

    static func watts(_ w: Double) -> String {
        abs(w) >= 10 ? String(format: "%.0f W", w) : String(format: "%.1f W", w)
    }

    static func temp(_ t: Double) -> String {
        "\(Int(t.rounded()))°"
    }

    static func loadColor(_ v: Double) -> Color {
        switch v {
        case ..<0.5: return .green
        case ..<0.75: return .yellow
        case ..<0.9: return .orange
        default: return .red
        }
    }

    static func tempColor(_ t: Double) -> Color {
        switch t {
        case ..<60: return .green
        case ..<80: return .orange
        default: return .red
        }
    }
}
