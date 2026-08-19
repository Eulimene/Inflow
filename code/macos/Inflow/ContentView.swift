import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "doc.text")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            Text("Inflow")
                .font(.largeTitle.weight(.semibold))

            Text("本地优先的 Markdown 写作工作台")
                .font(.title3)
                .foregroundStyle(.secondary)

            Label(
                InflowCoreBridge.isCompatible
                    ? "Rust 核心已连接 · ABI \(InflowCoreBridge.abiVersion)"
                    : "Rust 核心版本不兼容",
                systemImage: InflowCoreBridge.isCompatible ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
            )
            .font(.callout.monospacedDigit())
            .foregroundStyle(InflowCoreBridge.isCompatible ? Color.green : Color.orange)
            .accessibilityLabel(
                InflowCoreBridge.isCompatible
                    ? "Rust 核心已连接，ABI 版本 \(InflowCoreBridge.abiVersion)"
                    : "Rust 核心版本不兼容"
            )
        }
        .padding(40)
    }
}
