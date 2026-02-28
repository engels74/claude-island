//
//  WhatsNewView.swift
//  ClaudeIsland
//
//  Displays a scrollable list of release notes fetched from GitHub.
//

import SwiftUI

struct WhatsNewView: View {
    // MARK: Lifecycle

    init(onBack: @escaping () -> Void) {
        self.onBack = onBack
    }

    // MARK: Internal

    let onBack: () -> Void

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(spacing: 4) {
                HStack(spacing: 10) {
                    Button(action: self.onBack) {
                        HStack(spacing: 10) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 12))
                                .foregroundColor(.white.opacity(0.7))
                                .frame(width: 16)

                            Text("What's New")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.white.opacity(0.7))

                            Spacer()

                            if self.releaseService.isLoading {
                                ProgressView()
                                    .scaleEffect(0.5)
                                    .frame(width: 12, height: 12)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(self.isHeaderHovered ? Color.white.opacity(0.08) : Color.clear),
                        )
                    }
                    .buttonStyle(.plain)
                    .onHover { self.isHeaderHovered = $0 }
                }

                Divider()
                    .background(Color.white.opacity(0.08))
                    .padding(.vertical, 4)

                if self.releaseService.releases.isEmpty, self.releaseService.isLoading {
                    VStack(spacing: 8) {
                        ProgressView()
                        Text("Loading...")
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.4))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                } else if self.releaseService.releases.isEmpty, let errorMessage = self.releaseService.errorMessage {
                    VStack(spacing: 8) {
                        Text(errorMessage)
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.5))
                            .multilineTextAlignment(.center)

                        Button {
                            Task { await self.releaseService.fetchReleases() }
                        } label: {
                            Text("Retry")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(TerminalColors.blue)
                        }
                        .buttonStyle(.plain)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                } else {
                    ForEach(Array(self.releaseService.releases.enumerated()), id: \.element.id) { index, release in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(release.name)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(.white)

                                if self.isInstalled(release) {
                                    Text("Installed")
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundColor(TerminalColors.green)
                                }

                                Spacer()

                                Text(release.publishedAt.formatted(date: .abbreviated, time: .omitted))
                                    .font(.system(size: 11))
                                    .foregroundColor(.white.opacity(0.4))
                            }
                            .padding(.horizontal, 12)

                            ForEach(Array(release.changes.enumerated()), id: \.offset) { _, change in
                                HStack(alignment: .top, spacing: 8) {
                                    Circle()
                                        .fill(Color.white.opacity(0.3))
                                        .frame(width: 4, height: 4)
                                        .padding(.top, 5)

                                    Text(change)
                                        .font(.system(size: 12))
                                        .foregroundColor(.white.opacity(0.7))
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .padding(.leading, 28)
                                .padding(.trailing, 12)
                            }
                        }
                        .padding(.vertical, 4)

                        if index < self.releaseService.releases.count - 1 {
                            Divider()
                                .background(Color.white.opacity(0.08))
                                .padding(.vertical, 4)
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task {
            await self.releaseService.fetchReleases()
        }
    }

    // MARK: Private

    @State private var isHeaderHovered = false

    private var releaseService = ReleaseService.shared

    private var installedVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    private func isInstalled(_ release: ReleaseInfo) -> Bool {
        let version = release.id.hasPrefix("v") ? String(release.id.dropFirst()) : release.id
        return version == self.installedVersion
    }
}
