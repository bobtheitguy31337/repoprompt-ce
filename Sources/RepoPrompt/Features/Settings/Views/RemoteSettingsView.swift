import AppKit
import CoreImage
import RepoPromptRemoteProtocol
import SwiftUI

struct RemoteSettingsView: View {
    @ObservedObject private var gateway = RemoteGatewayController.shared
    @ObservedObject private var availability = RemoteAvailabilityController.shared

    private static let authorityLevels: [RemoteAuthorityLevel] = [
        .observe, .respond, .control, .danger
    ]

    private enum ElevationPreset: String, CaseIterable, Identifiable {
        case once
        case fifteenMinutes
        case persistent

        var id: String {
            rawValue
        }

        var title: String {
            switch self {
            case .once: "Next command only"
            case .fifteenMinutes: "15 minutes"
            case .persistent: "Until revoked"
            }
        }
    }

    @State private var elevationLevel: RemoteAuthorityLevel = .control
    @State private var elevationPreset: ElevationPreset = .once

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                gatewaySection
                pairingSection
                authorizationSection
                availabilitySection
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            RemoteGatewayController.shared.configure(windowStatesManager: WindowStatesManager.shared)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Connect your phone")
                .font(.largeTitle.weight(.semibold))
            Text("Connect RepoPrompt Remote to this Mac. Your Mac remains in control of its projects and agents.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var gatewaySection: some View {
        GroupBox("Remote access") {
            VStack(alignment: .leading, spacing: 14) {
                Toggle("Enable pairing", isOn: Binding(
                    get: { gateway.isEnabled },
                    set: { enabled in
                        Task { await gateway.setEnabled(enabled) }
                    }
                ))

                Text("Allow RepoPrompt Remote to connect to this Mac. Pairing is required before anything can be viewed or controlled.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                if gateway.isRunning {
                    LabeledContent("Status") {
                        Label("Ready for pairing", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                } else {
                    LabeledContent("Status") {
                        Text(gateway.lastError ?? "Disabled")
                            .foregroundStyle(gateway.lastError == nil ? Color.secondary : Color.red)
                    }
                }

                if let error = gateway.lastError, !error.isEmpty {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
            .padding(8)
        }
    }

    private var pairingSection: some View {
        GroupBox("Pair your phone") {
            VStack(alignment: .leading, spacing: 14) {
                if let pairingCode = gateway.pairingCode {
                    HStack(alignment: .top, spacing: 20) {
                        PairingQRCodeView(payload: pairingCode)

                        VStack(alignment: .leading, spacing: 10) {
                            Text("Scan this code with RepoPrompt Remote")
                                .font(.headline)
                            Text("The code stays valid until it is used or you generate a new code. Generating a new code invalidates the previous one.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            HStack {
                                Button("Generate new code") {
                                    gateway.refreshPairingAdvertisement()
                                }
                                Button("Copy pairing link") {
                                    copyPairingLink()
                                }
                                .disabled(gateway.pairingCode == nil)
                            }
                        }
                    }
                } else {
                    Text(gateway.isEnabled ? "Start pairing to generate a code." : "Enable pairing to generate a code.")
                        .foregroundStyle(.secondary)
                    Button("Generate pairing code") {
                        gateway.refreshPairingAdvertisement()
                    }
                    .disabled(!gateway.isRunning)
                }

                LabeledContent("Paired phone") {
                    Text(gateway.isPaired ? "One device paired" : "None")
                        .foregroundStyle(gateway.isPaired ? .primary : .secondary)
                }

                if gateway.isPaired {
                    Button("Unpair phone", role: .destructive) {
                        gateway.revokePairedDevice()
                    }
                }
            }
            .padding(8)
        }
    }

    private var authorizationSection: some View {
        GroupBox("Default authorization") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Default authority", selection: Binding(
                    get: { gateway.defaultAuthority },
                    set: { gateway.defaultAuthority = $0 }
                )) {
                    ForEach(Self.authorityLevels, id: \.rawValue) { level in
                        Text(authorityTitle(level)).tag(level)
                    }
                }
                .pickerStyle(.menu)

                Text("Observe is the recommended default. Higher levels control which paired-device commands the Mac will accept.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                Text("Temporary elevation")
                    .font(.headline)
                Picker("Grant authority", selection: $elevationLevel) {
                    ForEach(Self.authorityLevels.filter { $0 > .observe }, id: \.rawValue) { level in
                        Text(authorityTitle(level)).tag(level)
                    }
                }
                .pickerStyle(.menu)
                Picker("Duration", selection: $elevationPreset) {
                    ForEach(ElevationPreset.allCases) { preset in
                        Text(preset.title).tag(preset)
                    }
                }
                .pickerStyle(.menu)
                HStack {
                    Button("Grant temporary authority") {
                        switch elevationPreset {
                        case .once:
                            gateway.grantAuthority(level: elevationLevel, duration: .once)
                        case .fifteenMinutes:
                            gateway.grantAuthority(
                                level: elevationLevel,
                                duration: .limited(until: Date().addingTimeInterval(15 * 60))
                            )
                        case .persistent:
                            gateway.grantAuthority(level: elevationLevel, duration: .persistent)
                        }
                    }
                    if gateway.activeAuthorityGrant != nil {
                        Button("Revoke elevation", role: .destructive) {
                            gateway.clearAuthorityGrant()
                        }
                    }
                }
                if let grant = gateway.activeAuthorityGrant {
                    Text(grantDescription(grant))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(8)
        }
    }

    private var availabilitySection: some View {
        GroupBox("Desktop availability") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Launch RepoPrompt at login", isOn: Binding(
                    get: { availability.launchAtLoginEnabled },
                    set: { availability.setLaunchAtLogin($0) }
                ))

                LabeledContent("Active-run sleep policy") {
                    Text(availability.preventsIdleSleepForActiveRun ? "Keeping Mac awake" : "Not asserted")
                        .foregroundStyle(availability.preventsIdleSleepForActiveRun ? .green : .secondary)
                }

                Text("The Mac stays awake only while an agent is opening, working, blocked, or waiting for input.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let error = availability.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
            .padding(8)
        }
    }

    private func copyPairingLink() {
        guard let pairingCode = gateway.pairingCode else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(pairingCode, forType: .string)
    }

    private func authorityTitle(_ level: RemoteAuthorityLevel) -> String {
        switch level {
        case .observe: "Observe (read-only)"
        case .respond: "Respond"
        case .control: "Control"
        case .danger: "Danger"
        }
    }

    private func grantDescription(_ grant: RemoteAuthorityGrant) -> String {
        let level = authorityTitle(grant.level)
        switch grant.duration {
        case .once:
            return "\(level) is granted for the next successful command."
        case .session:
            return "\(level) is granted for the current session."
        case let .limited(until):
            return "\(level) is granted until \(until.formatted(date: .omitted, time: .shortened))."
        case .persistent:
            return "\(level) remains granted until revoked."
        }
    }
}

private struct PairingQRCodeView: View {
    let payload: String

    @State private var image: Image?

    var body: some View {
        Group {
            if let image {
                image
                    .interpolation(.none)
                    .resizable()
            } else {
                ProgressView()
            }
        }
        .frame(width: 220, height: 220)
        .padding(10)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: payload) {
            image = Self.makeImage(for: payload)
        }
    }

    private static func makeImage(for payload: String) -> Image? {
        let filter = CIFilter(name: "CIQRCodeGenerator")
        filter?.setValue(Data(payload.utf8), forKey: "inputMessage")
        filter?.setValue("Q", forKey: "inputCorrectionLevel")
        guard let output = filter?.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        guard let cgImage = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return Image(decorative: cgImage, scale: 1, orientation: .up)
    }
}
