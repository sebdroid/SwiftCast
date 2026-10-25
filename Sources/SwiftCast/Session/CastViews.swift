#if canImport(SwiftUI)
import SwiftUI

/// A list of nearby Cast devices. Selecting a device connects the session;
/// selecting the connected device again disconnects it.
public struct CastDevicePicker: View {
    @Bindable private var session: CastSession
    @State private var browser = CastDeviceBrowser()
    @State private var error: CastError?
    private let onSelect: (() -> Void)?

    public init(session: CastSession, onSelect: (() -> Void)? = nil) {
        self.session = session
        self.onSelect = onSelect
    }

    public var body: some View {
        List {
            Section {
                if browser.devices.isEmpty {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text(browser.problem ?? String(localized: "Looking for devices…"))
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(browser.devices) { device in
                    Button {
                        select(device)
                    } label: {
                        row(for: device)
                    }
                }
            } footer: {
                if let error {
                    Text(error.localizedDescription).foregroundStyle(.red)
                }
            }

            if session.device != nil {
                Section {
                    Button(role: .destructive) {
                        Task { await session.disconnect(stopApplication: true) }
                        onSelect?()
                    } label: {
                        Label("Stop Casting", systemImage: "stop.circle")
                    }
                }
            }
        }
        .task { await browser.run() }
    }

    private func icon(for kind: CastDevice.Kind) -> String {
        switch kind {
        case .group: "hifispeaker.2"
        case .tv: "tv"
        case .speaker: "hifispeaker"
        case .generic: "dot.radiowaves.left.and.right"
        }
    }

    private func row(for device: CastDevice) -> some View {
        HStack {
            Image(systemName: icon(for: device.kind))
                .frame(width: 28)
            VStack(alignment: .leading) {
                Text(device.name)
                if let status = device.statusText {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                } else if let model = device.modelName {
                    Text(model).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            switch session.connectionState {
            case .connected(let current) where current.id == device.id:
                Image(systemName: "checkmark").foregroundStyle(.tint)
            case .connecting(let current) where current.id == device.id,
                 .reconnecting(let current, _) where current.id == device.id:
                ProgressView()
            default:
                EmptyView()
            }
        }
        .contentShape(Rectangle())
    }

    private func select(_ device: CastDevice) {
        error = nil
        if session.device?.id == device.id, session.isConnected {
            Task { await session.disconnect() }
            onSelect?()
            return
        }
        Task {
            do {
                try await session.connect(to: device)
                onSelect?()
            } catch {
                self.error = (error as? CastError) ?? .connectionFailed(error.localizedDescription)
            }
        }
    }
}

/// A toolbar-friendly button that shows the ``CastDevicePicker`` in a sheet
/// and reflects the session's connection state.
public struct CastButton: View {
    private let session: CastSession
    @State private var isPresented = false

    public init(session: CastSession) {
        self.session = session
    }

    public var body: some View {
        Button {
            isPresented = true
        } label: {
            Label("Cast", systemImage: symbolName)
                .symbolEffect(.pulse, isActive: isBusy)
        }
        .accessibilityValue(session.device?.name ?? "")
        .sheet(isPresented: $isPresented) {
            NavigationStack {
                CastDevicePicker(session: session) { isPresented = false }
                    .navigationTitle("Cast to Device")
                    #if !os(tvOS) && !os(macOS)
                    .navigationBarTitleDisplayMode(.inline)
                    #endif
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { isPresented = false }
                        }
                    }
            }
            #if os(macOS)
            .frame(minWidth: 320, minHeight: 360)
            #endif
        }
    }

    private var isBusy: Bool {
        switch session.connectionState {
        case .connecting, .reconnecting: true
        default: false
        }
    }

    private var symbolName: String {
        session.isConnected ? "tv.inset.filled" : "tv"
    }
}
#endif
