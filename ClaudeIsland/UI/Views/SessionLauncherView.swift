//
//  SessionLauncherView.swift
//  ClaudeIsland
//
//  Session launcher view (stub -- full implementation in Task 6)
//

import SwiftUI

struct SessionLauncherView: View {
    let onSubmit: (String, String, String) -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Session Launcher")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.white)

            Text("Full implementation pending")
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.5))
        }
        .frame(width: 500, height: 300)
    }
}
