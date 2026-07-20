import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var store = CaseStore()
    @State private var presentsImporter = false

    var body: some View {
        NavigationSplitView {
            Sidebar(store: store, presentsImporter: $presentsImporter)
                .navigationSplitViewColumnWidth(min: 310, ideal: 360, max: 430)
        } detail: {
            detail
        }
        .tint(.praesciaAmber)
        .fileImporter(
            isPresented: $presentsImporter,
            allowedContentTypes: [.nifti, .gzip, .data],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first { store.open(url) }
            if case .failure(let error) = result { store.state = .failed(error.localizedDescription) }
        }
        .task {
#if DEBUG
            store.configureForUITestingIfNeeded()
#endif
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch store.state {
        case .empty:
            WelcomeView { presentsImporter = true }
        case .loading(let message):
            LoadingView(message: message)
        case .failed(let message):
            ErrorView(message: message) { presentsImporter = true }
        case .loaded(let scan):
            AnatomyView(scan: scan, store: store)
        }
    }
}

private struct Sidebar: View {
    let store: CaseStore
    @Binding var presentsImporter: Bool

    var body: some View {
        ZStack {
            Color.praesciaPaper.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    brand
                    if let scan = store.scan {
                        acquisition(scan)
                        regions(scan)
                        explanation(scan)
                    } else {
                        Button("Open NIfTI scan", systemImage: "folder.badge.plus") { presentsImporter = true }
                            .buttonStyle(.borderedProminent)
                    }
                    safetyNotice
                }
                .padding(24)
            }
        }
        .toolbar {
            if store.scan != nil {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close case", systemImage: "xmark") { store.close() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Open", systemImage: "folder") { presentsImporter = true }
                }
            }
        }
    }

    private var brand: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("PRAESCIA")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .tracking(3)
                .foregroundStyle(Color.praesciaAmber)
            Text("Scan atlas")
                .font(.system(size: 32, weight: .semibold, design: .serif))
                .foregroundStyle(Color.praesciaInk)
        }
    }

    private func acquisition(_ scan: ProcessedScan) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(text: "ACQUISITION")
            FactRow(label: "Grid", value: "\(scan.metadata.dimensions.x) × \(scan.metadata.dimensions.y) × \(scan.metadata.dimensions.z)")
            FactRow(label: "Voxel", value: scan.metadata.voxelSizeMM.formattedMM)
            FactRow(label: "Type", value: scan.metadata.dataType)
            FactRow(label: "Display", value: scan.displayStride == 1 ? "Full surface sampling" : "1 in \(scan.displayStride) surface sampling")
            if scan.displayStride > 1 {
                Text("The 3D surface is reduced for interactive performance. Volumes still use every voxel.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func regions(_ scan: ProcessedScan) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(text: "INTENSITY BANDS")
            Text("A deterministic Otsu foreground cutoff and histogram split, not anatomical or diagnostic segmentation.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            ForEach(scan.regions) { region in
                HStack(spacing: 10) {
                    Button {
                        store.toggleVisibility(region.id)
                    } label: {
                        Image(systemName: store.visibleRegionIDs.contains(region.id) ? "eye.fill" : "eye.slash")
                            .foregroundStyle(Color(red: Double(region.color.x), green: Double(region.color.y), blue: Double(region.color.z)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("region-visibility-\(region.id)")
                    .accessibilityLabel("\(region.name) visibility")
                    .accessibilityValue(store.visibleRegionIDs.contains(region.id) ? "Visible" : "Hidden")
                    Button {
                        store.selectedRegionID = region.id
                    } label: {
                        HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(region.name).font(.callout.weight(.semibold))
                            Text("\(region.volumeML, format: .number.precision(.fractionLength(1))) mL")
                                .font(.system(.body, design: .monospaced))
                        }
                        Spacer()
                        if store.selectedRegionID == region.id { Image(systemName: "circle.inset.filled") }
                    }
                        .foregroundStyle(Color.praesciaInk)
                        .padding(10)
                        .background(store.selectedRegionID == region.id ? Color.white.opacity(0.82) : Color.clear, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("region-select-\(region.id)")
                }
            }
            FactRow(label: "Segmented total", value: String(format: "%.1f mL", scan.segmentedVolumeML))
        }
    }

    private func explanation(_ scan: ProcessedScan) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "PLAIN-LANGUAGE NOTE")
            if let region = scan.regions.first(where: { $0.id == store.selectedRegionID }) {
                let percentage = scan.segmentedVolumeML > 0 ? region.volumeML / scan.segmentedVolumeML * 100 : 0
                Text("This band contains scan voxels in the \(region.name.lowercased()) range. It occupies \(region.volumeML, format: .number.precision(.fractionLength(1))) mL, or \(percentage, format: .number.precision(.fractionLength(1)))% of the segmented volume. Intensity alone does not identify a tissue or medical finding.")
                    .font(.callout)
                    .foregroundStyle(Color.praesciaInk)
                    .accessibilityIdentifier("region-description")
                Label("Source: deterministic computed fallback", systemImage: "function")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("description-source")
            } else {
                Text("Select a band to see its computed summary.").font(.callout)
            }
        }
    }

    private var safetyNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Research prototype", systemImage: "exclamationmark.shield")
                .font(.headline)
            Text("For education, consent conversations, and review only. Not a medical device. Not for diagnosis, treatment decisions, surgical planning, or intraoperative guidance.")
                .font(.footnote)
        }
        .foregroundStyle(.white)
        .padding(16)
        .background(Color.praesciaInk, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityIdentifier("safety-notice")
    }
}

private struct WelcomeView: View {
    let open: () -> Void

    var body: some View {
        ZStack {
            LinearGradient(colors: [.praesciaInk, Color(red: 0.08, green: 0.19, blue: 0.22)], startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()
            Circle()
                .stroke(Color.praesciaAmber.opacity(0.18), lineWidth: 70)
                .frame(width: 540, height: 540)
                .offset(x: 280, y: -220)
            VStack(alignment: .leading, spacing: 24) {
                Spacer()
                Text("Turn a scan\ninto a map.")
                    .font(.system(size: 64, weight: .semibold, design: .serif))
                    .foregroundStyle(.white)
                Text("Open a .nii or .nii.gz brain MRI. Processing stays entirely on this iPad.")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.72))
                    .frame(maxWidth: 540, alignment: .leading)
                Button("Choose a scan", systemImage: "folder.badge.plus", action: open)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accessibilityIdentifier("welcome-open-scan")
                Spacer()
                Text("RESEARCH PROTOTYPE · NOT FOR DIAGNOSIS")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .tracking(2)
                    .foregroundStyle(Color.praesciaAmber)
                    .accessibilityIdentifier("safety-notice")
            }
            .padding(64)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct LoadingView: View {
    let message: String
    var body: some View {
        ZStack {
            Color.praesciaInk.ignoresSafeArea()
            VStack(spacing: 18) {
                ProgressView().controlSize(.large).tint(.praesciaAmber)
                Text(message).font(.title3).foregroundStyle(.white)
                Text("Decompression, segmentation, and geometry run on device.")
                    .font(.footnote).foregroundStyle(.white.opacity(0.62))
            }
        }
    }
}

private struct ErrorView: View {
    let message: String
    let retry: () -> Void
    var body: some View {
        ContentUnavailableView {
            Label("Scan could not be opened", systemImage: "waveform.path.ecg.rectangle")
        } description: {
            Text(message)
                .accessibilityIdentifier("scan-error-message")
        } actions: {
            Button("Choose another file", action: retry)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("scan-error-retry")
        }
    }
}

private struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 11, weight: .bold, design: .rounded)).tracking(1.8).foregroundStyle(.secondary)
    }
}

private struct FactRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).multilineTextAlignment(.trailing).foregroundStyle(Color.praesciaInk)
        }
        .font(.callout)
    }
}

private extension SIMD3 where Scalar == Double {
    var formattedMM: String { String(format: "%.3g × %.3g × %.3g mm", x, y, z) }
}

extension UTType {
    static let nifti = UTType(filenameExtension: "nii") ?? .data
    static let gzip = UTType(filenameExtension: "gz") ?? .data
}

extension Color {
    static let praesciaInk = Color(red: 0.035, green: 0.105, blue: 0.12)
    static let praesciaPaper = Color(red: 0.94, green: 0.925, blue: 0.87)
    static let praesciaAmber = Color(red: 0.93, green: 0.58, blue: 0.18)
}

#Preview { ContentView() }
