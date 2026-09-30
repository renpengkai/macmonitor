//
// Glass.swift
// MacMonitor
// 液态玻璃适配: macOS 26+ 使用 glassEffect, 更早系统回退为毛玻璃材质。
// `#if compiler(>=6.2)` 保证用旧版 Xcode (无 macOS 26 SDK) 也能编译。
//

import SwiftUI

extension View {

    func glassCard(cornerRadius: CGFloat = 16) -> some View {
        modifier(GlassCard(cornerRadius: cornerRadius))
    }

    @ViewBuilder
    func glassButton() -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.bordered)
        }
        #else
        self.buttonStyle(.bordered)
        #endif
    }
}

private struct GlassCard: ViewModifier {
    let cornerRadius: CGFloat

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            content.padding(12).glassEffect(.regular, in: shape)
        } else {
            fallback(content, shape)
        }
        #else
        fallback(content, shape)
        #endif
    }

    private func fallback(_ content: Content, _ shape: RoundedRectangle) -> some View {
        content
            .padding(12)
            .background(.regularMaterial, in: shape)
            .overlay(shape.strokeBorder(.white.opacity(0.08)))
    }
}

/// 多块玻璃放进同一个容器, macOS 26 上相邻玻璃会共享采样与融合动画
struct GlassStack<Content: View>: View {
    var spacing: CGFloat = 10
    @ViewBuilder var content: Content

    @ViewBuilder
    var body: some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                VStack(spacing: spacing) { content }
            }
        } else {
            VStack(spacing: spacing) { content }
        }
        #else
        VStack(spacing: spacing) { content }
        #endif
    }
}
