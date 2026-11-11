import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import AgentProfilesCore

/// An import that was read and waits for the answer of its preview sheet.
struct ImportPreview: Identifiable {
    let id = UUID()
    /// The name of the file, shown in the sheet.
    var fileName: String
    /// The profiles of the file and what they collide with.
    var candidates: [ImportCandidate]
    /// What the user chose for the conflicts. A conflict without a choice is skipped.
    var choices: [Int: ImportChoice] = [:]
    /// What the import will do, per candidate. Worked out when a choice
    /// changes, never while the sheet is drawn.
    var actions: [ImportAction] = []

    /// The number of profiles that will be created.
    var createCount: Int {
        actions.filter { if case .create = $0 { return true } else { return false } }.count
    }
}

/// "Export Profiles…" and "Import Profiles…".
extension AppModel {
    // MARK: - Export

    /// Asks where to write the export file, then writes the settings of every
    /// profile of the user into it. Keys and the default setup are never written.
    func exportProfiles() {
        let profiles = userProfiles
        guard !profiles.isEmpty else {
            status = Status(kind: .hint, text: loc.t("export.empty"))
            return
        }
        let panel = NSSavePanel()
        panel.title = loc.t("menu.exportProfiles")
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = ProfileExport.defaultFileName(for: Date())
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ProfileExport.write(ProfileExport.encode(profiles, exportedAt: Date()), to: url)
            status = Status(kind: .success, text: loc.t("export.done", String(profiles.count), url.path))
        } catch {
            status = Status(kind: .failure, text: loc.t("export.failed", url.path))
        }
    }

    // MARK: - Import

    /// Asks for an export file, reads it and opens the preview. A file that
    /// cannot be imported is explained and nothing changes.
    func importProfiles() {
        guard !dataFailed else {
            status = Status(kind: .failure, text: loc.t("import.dataNotLoaded"))
            return
        }
        let panel = NSOpenPanel()
        panel.title = loc.t("menu.importProfiles")
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let document: ExportDocument
        do {
            document = try ProfileExport.read(from: url)
        } catch {
            showImportAlert(title: loc.t("import.error.title"), message: importMessage(for: error))
            return
        }
        guard !document.profiles.isEmpty else {
            showImportAlert(title: loc.t("import.error.title"), message: loc.t("import.empty"))
            return
        }
        let store = self.store
        let candidates = ImportPlanner.candidates(
            for: document.profiles,
            existing: data.profiles,
            isCommandTaken: { store.isCommandTakenOnDisk($0) }
        )
        var preview = ImportPreview(fileName: url.lastPathComponent, candidates: candidates)
        preview.actions = importActions(for: preview)
        importPreview = preview
    }

    /// The choice of the user for one conflicting profile. The value that is
    /// already there is not written again.
    func setImportChoice(_ choice: ImportChoice, for id: Int) {
        guard SettingsChange.isDifferent(importPreview?.choices[id] ?? .skip, choice),
              var preview = importPreview
        else { return }
        preview.choices[id] = choice
        preview.actions = importActions(for: preview)
        importPreview = preview
    }

    /// Closes the preview without importing anything.
    func cancelImport() {
        importPreview = nil
    }

    /// Creates the profiles of the preview, each through the normal save of
    /// its launcher and its folder, then writes `profiles.json` once.
    ///
    /// A profile that fails is reported and the others are still imported.
    func confirmImport() {
        guard let preview = importPreview else { return }
        importPreview = nil
        guard !dataFailed else {
            status = Status(kind: .failure, text: loc.t("import.dataNotLoaded"))
            return
        }

        var imported: [Profile] = []
        var skipped: [String] = []
        var failures: [String] = []
        for (candidate, action) in zip(preview.candidates, preview.actions) {
            switch action {
            case .skip:
                skipped.append(candidate.profile.name)
            case .create(let profile):
                do {
                    // The store checks again that nothing takes the name or
                    // the command: the disk may have changed since the preview.
                    try store.saveImportedProfile(profile, others: data.profiles, strings: loc.scriptStrings)
                    data.profiles.append(profile)
                    imported.append(profile)
                } catch {
                    failures.append("\(profile.name): \(importMessage(for: error))")
                }
            }
        }

        var lines: [String] = []
        if imported.isEmpty {
            lines.append(loc.t("import.result.none"))
        } else {
            lines.append(loc.t("import.result.imported", imported.map(\.name).joined(separator: ", ")))
            let needKey = imported.filter { $0.auth != .none }
            if !needKey.isEmpty {
                lines.append(loc.t("import.result.needKey", needKey.map(\.name).joined(separator: ", ")))
            }
        }
        if !skipped.isEmpty {
            lines.append(loc.t("import.result.skipped", skipped.joined(separator: ", ")))
        }
        if !failures.isEmpty {
            lines.append(loc.t("import.result.failed", failures.joined(separator: "\n")))
        }

        if !imported.isEmpty {
            // One write for the whole import.
            do {
                try store.save(data)
                status = Status(kind: .success, text: loc.t("import.status.done", imported.map(\.name).joined(separator: ", ")))
            } catch {
                let reason = importMessage(for: error)
                lines.append(loc.t("import.result.saveFailed", reason))
                status = Status(kind: .failure, text: loc.t("import.result.saveFailed", reason))
            }
            profilesImported()
        }
        showImportAlert(title: loc.t("import.result.title"), message: lines.joined(separator: "\n\n"))
    }

    /// What the import does with each profile of the preview.
    private func importActions(for preview: ImportPreview) -> [ImportAction] {
        let store = self.store
        return ImportPlanner.actions(
            for: preview.candidates,
            choices: preview.choices,
            existing: data.profiles,
            isCommandTaken: { store.isCommandTakenOnDisk($0) }
        )
    }

    /// A sentence for an error of the import, in the language of the user.
    private func importMessage(for error: Error) -> String {
        switch error {
        case let exportError as ProfileExportError:
            switch exportError {
            case .notAnExport:
                return loc.t("import.error.notAnExport")
            case .unsupportedVersion(let version):
                return loc.t("import.error.version", version)
            case .invalidProfile(let number):
                return loc.t("import.error.invalidProfile", String(number))
            case .duplicateProfile(let slug):
                return loc.t("import.error.duplicate", slug)
            case .fileTooLarge:
                return loc.t("import.error.tooLarge")
            case .unreadable:
                return loc.t("import.error.unreadable")
            case .writeFailed(let path):
                return loc.t("export.failed", path)
            }
        case let profileError as ProfileError:
            return profileError.localizedMessage(loc)
        case let storeError as StoreError:
            return storeError.localizedMessage(loc)
        default:
            return loc.t("error.generic")
        }
    }

    private func showImportAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: loc.t("actions.close"))
        alert.runModal()
    }
}

/// The preview of an import: every profile of the file with its status, and
/// for a conflict the choice between Skip and Import as copy.
struct ImportPreviewView: View {
    @Bindable var model: AppModel
    let preview: ImportPreview

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.loc.t("import.preview.title"))
                .font(.headline)
            Text(model.loc.t("import.preview.file", preview.fileName))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            List {
                ForEach(Array(preview.candidates.enumerated()), id: \.element.id) { index, candidate in
                    row(candidate, action: preview.actions.indices.contains(index) ? preview.actions[index] : .skip)
                }
            }
            .frame(minHeight: 200)
            Text(model.loc.t("import.preview.note"))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(model.loc.t("actions.cancel"), role: .cancel) { model.cancelImport() }
                    .keyboardShortcut(.cancelAction)
                Button(model.loc.t("import.preview.import")) { model.confirmImport() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(preview.createCount == 0)
            }
        }
        .padding(20)
        .frame(width: 520, height: 440)
    }

    private func row(_ candidate: ImportCandidate, action: ImportAction) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.profile.name)
                Text(model.store.paths.command(for: candidate.profile.slug))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Text(statusText(candidate.status))
                    .font(.caption)
                    .foregroundStyle(candidate.status.isConflict ? Color(nsColor: .systemOrange) : .secondary)
                if candidate.status.isConflict, case .create(let copy) = action {
                    Text(model.loc.t("import.preview.copyAs", copy.name, model.store.paths.command(for: copy.slug)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if candidate.status.isConflict {
                Picker("", selection: choiceBinding(for: candidate.id)) {
                    Text(model.loc.t("import.choice.skip")).tag(ImportChoice.skip)
                    Text(model.loc.t("import.choice.copy")).tag(ImportChoice.importAsCopy)
                }
                .labelsHidden()
                .fixedSize()
            }
        }
        .padding(.vertical, 2)
    }

    private func statusText(_ status: ImportStatus) -> String {
        switch status {
        case .new: return model.loc.t("import.status.new")
        case .nameExists: return model.loc.t("import.status.nameExists")
        case .commandExists: return model.loc.t("import.status.commandExists")
        case .nameAndCommandExist: return model.loc.t("import.status.bothExist")
        }
    }

    private func choiceBinding(for id: Int) -> Binding<ImportChoice> {
        Binding(
            get: { model.importPreview?.choices[id] ?? .skip },
            set: { model.setImportChoice($0, for: id) }
        )
    }
}
