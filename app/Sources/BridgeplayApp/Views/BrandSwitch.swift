import BridgeplayUI
import SwiftUI

// A switch in the guidelines' toggle shape (38 × 22, white 18 pt knob) with the brand
// gradient as its "on" fill; off is a raise-2 track with a hairline.
struct BrandSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        BrandSwitch(configuration: configuration)
    }
}

private struct BrandSwitch: View {
    let configuration: ToggleStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let on = configuration.isOn
        ZStack(alignment: on ? .trailing : .leading) {
            Capsule()
                .fill(on ? AnyShapeStyle(BP.iridescent) : AnyShapeStyle(BP.raise2))
                .overlay(Capsule().strokeBorder(on ? .clear : BP.lineStrong, lineWidth: 1))
            Circle()
                .fill(.white)
                .frame(width: 18, height: 18)
                .shadow(color: .black.opacity(0.35), radius: 1.5, y: 1)
                .padding(2)
        }
        .frame(width: 38, height: 22)
        .opacity(isEnabled ? 1 : 0.4)
        .contentShape(Capsule())
        .onTapGesture { configuration.isOn.toggle() }
        .animation(.easeOut(duration: 0.18), value: on)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }
}

extension ToggleStyle where Self == BrandSwitchStyle {
    static var brandSwitch: BrandSwitchStyle { BrandSwitchStyle() }
}
