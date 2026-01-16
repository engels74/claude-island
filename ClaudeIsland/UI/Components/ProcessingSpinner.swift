//
//  ProcessingSpinner.swift
//  ClaudeIsland
//
//  Animated symbol spinner for processing state
//

import Combine
import SwiftUI

struct ProcessingSpinner: View {
    // MARK: Internal

    var body: some View {
        Text(self.symbols[self.phase % self.symbols.count])
            .font(.system(size: 12, weight: .bold))
            .foregroundColor(self.color)
            .frame(width: 12, alignment: .center)
            .onReceive(self.timer) { _ in
                self.phase = (self.phase + 1) % self.symbols.count
            }
    }

    // MARK: Private

    @State private var phase = 0

    private let symbols = ["·", "✢", "✳", "∗", "✻", "✽"]
    private let color = Color(red: 0.85, green: 0.47, blue: 0.34) // Claude orange

    /// @State ensures timer persists across view updates rather than being recreated
    @State private var timer = Timer.publish(every: 0.15, on: .main, in: .common).autoconnect()
}

#Preview {
    ProcessingSpinner()
        .frame(width: 30, height: 30)
        .background(.black)
}
