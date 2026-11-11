import AppKit
import Observation
import SwiftUI
import AgentProfilesCore

/// The Claude Code files of one profile as the editor holds them: the MCP
/// servers of `.claude.json` and the permission rules of `settings.json`.
///
/// The edits stay here until they are saved, so switching the tab or the
/// profile does not lose them. Saving writes only the file whose part changed.
@MainActor
@Observable
final class ClaudeConfigEditor {
    let location: ClaudeConfigLocation

    private var settingsDocument: ClaudeConfigDocument?
    private var stateDocument: ClaudeConfigDocument?
    /// Why `settings.json` could not be read. Its part cannot be saved then.
    private(set) var settingsError: ClaudeConfigError?
    /// Why `.claude.json` could not be read. Its part cannot be saved then.
    private(set) var stateError: ClaudeConfigError?

    var servers: [McpServer] = []
    private(set) var savedServers: [McpServer] = []
    var rules = PermissionRules()
    private(set) var savedRules = PermissionRules()

    init(location: ClaudeConfigLocation) {
        self.location = location
        load()
    }

    var hasChanges: Bool { servers != savedServers || rules != savedRules }

    /// `true` when the files may be written: an isolated profile, with each
    /// changed file read without an error.
    var canSave: Bool {
        guard location.isEditable, hasChanges else { return false }
        if servers != savedServers, stateError != nil { return false }
        if rules != savedRules, settingsError != nil { return false }
        return true
    }

    /// Reads both files again. The edits that were not saved are dropped.
    func load() {
        do {
            let document = try ClaudeConfigFile.readForDisplay(.settings, in: location)
            let read = try PermissionRules.read(from: document)
            settingsDocument = document
            rules = read
            savedRules = read
            settingsError = nil
        } catch {
            settingsDocument = nil
            rules = PermissionRules()
            savedRules = rules
            settingsError = error as? ClaudeConfigError ?? .readFailed(path: location.settingsFile.path)
        }
        do {
            let document = try ClaudeConfigFile.readForDisplay(.state, in: location)
            let read = try McpServers.read(from: document)
            stateDocument = document
            servers = read
            savedServers = read
            stateError = nil
        } catch {
            stateDocument = nil
            servers = []
            savedServers = []
            stateError = error as? ClaudeConfigError ?? .readFailed(path: location.stateFile.path)
        }
    }

    /// Puts the edits back, as they were read.
    func revert() {
        servers = savedServers
        rules = savedRules
    }

    /// Writes the changed files. Throws the first problem; a file that was
    /// already written stays written.
    func save() throws {
        guard location.isEditable else { throw ClaudeConfigError.notEditable(path: location.settingsFile.path) }
        // Nothing is written before every server is known to be complete.
        try McpServers.validate(servers)

        if rules != savedRules, var document = settingsDocument {
            try rules.apply(to: &document)
            settingsDocument = try ClaudeConfigFile.write(document, in: location)
            savedRules = try PermissionRules.read(from: settingsDocument!)
            rules = savedRules
        }
        if servers != savedServers, var document = stateDocument {
            try McpServers.apply(servers, to: &document)
            let written = try ClaudeConfigFile.write(document, in: location)
            stateDocument = written
            savedServers = try McpServers.read(from: written)
            servers = savedServers
        }
    }
}

/// The "Claude Code" tab of a profile: its MCP servers and its permission rules.
///
/// An isolated profile can edit them. The default setup and a profile that is
/// not isolated use the user's own files, which are only shown.
struct ClaudeConfigView: View {
    @Bindable var model: AppModel
    let profile: Profile
    @Bindable var editor: ClaudeConfigEditor

    /// The server open in the sheet, `nil` when the sheet is closed.
    @State private var editingServer: McpServer?
    @State private var isConfirmingSave = false

    private var loc: Loc { model.loc }
    private var isRunning: Bool { model.terminals.book.runningCount(for: profile.slug) > 0 }

    var body: some View {
        Form {
            filesSection
            serversSection
            permissionsSection
        }
        .formStyle(.grouped)
        .frame(minHeight: 200, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                if editor.location.isEditable {
                    actionBar
                }
                StatusBar(model: model)
            }
            .background(.bar)
        }
        .onAppear {
            // Unsaved edits are kept; otherwise the files are read again, so a
            // change made by Claude Code meanwhile shows.
            if !editor.hasChanges { editor.load() }
        }
        .sheet(item: $editingServer) { server in
            McpServerSheet(loc: loc, server: server, isNew: !editor.servers.contains { $0.id == server.id }) { edited in
                if let index = editor.servers.firstIndex(where: { $0.id == edited.id }) {
                    editor.servers[index] = edited
                } else {
                    editor.servers.append(edited)
                }
                editingServer = nil
            } onCancel: {
                editingServer = nil
            }
        }
        .alert(loc.t("claude.running.title"), isPresented: $isConfirmingSave) {
            Button(loc.t("claude.running.saveAnyway"), role: .destructive) { save() }
            Button(loc.t("actions.cancel"), role: .cancel) {}
        } message: {
            Text(loc.t("claude.running.message"))
        }
    }

    // MARK: - Sections

    private var filesSection: some View {
        Section(loc.t("claude.section")) {
            Text(loc.t("claude.hint"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            LabeledContent("settings.json") { pathText(editor.location.settingsFile) }
            LabeledContent(".claude.json") { pathText(editor.location.stateFile) }
            if !editor.location.isEditable {
                Label(loc.t(profile.isDefaultClaude ? "claude.readOnly.default" : "claude.readOnly.shared"),
                      systemImage: "lock")
                    .font(.callout)
                    .foregroundColor(Color(nsColor: .systemOrange))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Label(loc.t(isRunning ? "claude.running.now" : "claude.running.hint"), systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundColor(isRunning ? Color(nsColor: .systemOrange) : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 12) {
                Button(loc.t("claude.openSettings")) { open(editor.location.settingsFile) }
                Button(loc.t("claude.reveal")) { reveal(editor.location.settingsFile) }
                Button(loc.t("claude.reload")) { reload() }
            }
        }
    }

    private var serversSection: some View {
        Section {
            if let error = editor.stateError {
                problem(error, file: editor.location.stateFile)
            } else {
                if editor.servers.isEmpty {
                    Text(loc.t("claude.mcp.empty"))
                        .foregroundStyle(.secondary)
                }
                ForEach(editor.servers) { server in
                    serverRow(server)
                }
                if editor.location.isEditable {
                    Button(loc.t("claude.mcp.add")) { editingServer = McpServer(name: "") }
                }
            }
        } header: {
            Text(loc.t("claude.mcp.section"))
        } footer: {
            Text(loc.t("claude.mcp.footer"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func serverRow(_ server: McpServer) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(server.name).font(.body.weight(.medium))
                    Text(server.unsupportedType ?? server.transport.rawValue)
                        .font(.caption.monospaced())
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.15)))
                }
                Text(summary(of: server))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            if editor.location.isEditable {
                if server.isEditable {
                    Button(loc.t("claude.mcp.edit")) { editingServer = server }
                }
                Button(loc.t("claude.mcp.remove")) { editor.servers.removeAll { $0.id == server.id } }
            }
        }
    }

    /// One line about the server, with the secret values masked.
    private func summary(of server: McpServer) -> String {
        guard server.isEditable else { return loc.t("claude.mcp.unsupported") }
        var parts: [String] = []
        switch server.transport {
        case .stdio:
            parts.append(([server.command] + server.args).joined(separator: " "))
            if !server.env.isEmpty { parts.append("env: " + pairsText(server.env)) }
        case .http, .sse:
            parts.append(server.url)
            if !server.headers.isEmpty { parts.append(loc.t("claude.mcp.headers") + ": " + pairsText(server.headers)) }
        }
        return parts.joined(separator: "  ·  ")
    }

    private func pairsText(_ pairs: [ConfigPair]) -> String {
        pairs.map { pair in
            let value = SecretMask.looksSecret(key: pair.key, value: pair.value) ? SecretMask.masked(pair.value) : pair.value
            return "\(pair.key)=\(value)"
        }.joined(separator: " ")
    }

    private var permissionsSection: some View {
        Section {
            if let error = editor.settingsError {
                problem(error, file: editor.location.settingsFile)
            } else {
                ruleList(loc.t("claude.perm.allow"), rules: $editor.rules.allow)
                ruleList(loc.t("claude.perm.ask"), rules: $editor.rules.ask)
                ruleList(loc.t("claude.perm.deny"), rules: $editor.rules.deny)
            }
        } header: {
            Text(loc.t("claude.perm.section"))
        } footer: {
            Text(loc.t("claude.perm.footer"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func ruleList(_ title: String, rules: Binding<[String]>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            if rules.wrappedValue.isEmpty {
                Text(loc.t("claude.perm.none"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(rules.wrappedValue.indices, id: \.self) { index in
                HStack {
                    if editor.location.isEditable {
                        TextField("", text: Binding(
                            get: { rules.wrappedValue.indices.contains(index) ? rules.wrappedValue[index] : "" },
                            set: { text in
                                guard rules.wrappedValue.indices.contains(index), rules.wrappedValue[index] != text else { return }
                                rules.wrappedValue[index] = text
                            }
                        ), prompt: Text(verbatim: "Bash(npm run test *)"))
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                        .labelsHidden()
                        Button {
                            if rules.wrappedValue.indices.contains(index) { rules.wrappedValue.remove(at: index) }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help(loc.t("claude.perm.remove"))
                    } else {
                        Text(rules.wrappedValue[index])
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                    }
                }
            }
            if editor.location.isEditable {
                Button(loc.t("claude.perm.add")) { rules.wrappedValue.append("") }
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }

    private func problem(_ error: ClaudeConfigError, file: URL) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(ClaudeConfigView.message(for: error, loc: loc), systemImage: "xmark.octagon")
                .foregroundColor(Color(nsColor: .systemRed))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Button(loc.t("claude.reveal")) { reveal(file) }
        }
    }

    private func pathText(_ url: URL) -> some View {
        Text(url.path)
            .font(.system(.callout, design: .monospaced))
            .textSelection(.enabled)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    // MARK: - The bar

    private var actionBar: some View {
        HStack {
            Button(loc.t("actions.save")) {
                if isRunning { isConfirmingSave = true } else { save() }
            }
            .keyboardShortcut("s", modifiers: .command)
            .buttonStyle(.borderedProminent)
            .disabled(!editor.canSave)
            Button(loc.t("claude.revert")) { editor.revert() }
                .disabled(!editor.hasChanges)
            Spacer()
            if editor.hasChanges {
                Text(loc.t("actions.unsaved"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
    }

    // MARK: - Actions

    private func save() {
        do {
            try editor.save()
            model.status = AppModel.Status(kind: .success, text: loc.t("claude.saved"))
        } catch ClaudeConfigError.changedOnDisk(let path) {
            // Someone else wrote the file: what is there now is shown, and the
            // user makes the change again on top of it.
            editor.load()
            model.status = AppModel.Status(kind: .failure, text: loc.t("claude.error.changedOnDisk", path))
        } catch let error as ClaudeConfigError {
            model.status = AppModel.Status(kind: .failure, text: ClaudeConfigView.message(for: error, loc: loc))
        } catch {
            model.status = AppModel.Status(kind: .failure, text: error.localizedDescription)
        }
    }

    private func reload() {
        editor.load()
        model.status = AppModel.Status(kind: .hint, text: loc.t("claude.reloaded"))
    }

    private func open(_ file: URL) {
        if FileManager.default.fileExists(atPath: file.path) {
            NSWorkspace.shared.open(file)
        } else {
            reveal(file)
        }
    }

    /// Shows the file in Finder, or its folder when the file is not there.
    private func reveal(_ file: URL) {
        if FileManager.default.fileExists(atPath: file.path) {
            NSWorkspace.shared.activateFileViewerSelecting([file])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([file.deletingLastPathComponent()])
        }
    }

    /// The localized text of a problem with the files.
    static func message(for error: ClaudeConfigError, loc: Loc) -> String {
        switch error {
        case .notParsable(let path, let detail): return loc.t("claude.error.notParsable", path, detail)
        case .notAnObject(let path): return loc.t("claude.error.notAnObject", path)
        case .unexpectedShape(let path, let key): return loc.t("claude.error.unexpectedShape", key, path)
        case .changedOnDisk(let path): return loc.t("claude.error.changedOnDisk", path)
        case .symlink(let path): return loc.t("claude.error.symlink", path)
        case .outsideFolder(let path): return loc.t("claude.error.outsideFolder", path)
        case .notAFile(let path): return loc.t("claude.error.notAFile", path)
        case .notEditable(let path): return loc.t("claude.error.notEditable", path)
        case .readFailed(let path): return loc.t("claude.error.readFailed", path)
        case .writeFailed(let path): return loc.t("claude.error.writeFailed", path)
        case .emptyServerName: return loc.t("claude.error.emptyServerName")
        case .duplicateServerName(let name): return loc.t("claude.error.duplicateServerName", name)
        case .incompleteServer(let name): return loc.t("claude.error.incompleteServer", name)
        }
    }
}

/// The sheet that adds or edits one MCP server.
struct McpServerSheet: View {
    let loc: Loc
    let isNew: Bool
    let onSave: (McpServer) -> Void
    let onCancel: () -> Void

    @State private var server: McpServer
    /// The arguments, one per line: an argument may hold spaces.
    @State private var argsText: String
    /// The pairs whose secret value is shown in plain text.
    @State private var revealed: Set<UUID> = []

    init(loc: Loc, server: McpServer, isNew: Bool, onSave: @escaping (McpServer) -> Void, onCancel: @escaping () -> Void) {
        self.loc = loc
        self.isNew = isNew
        self.onSave = onSave
        self.onCancel = onCancel
        _server = State(initialValue: server)
        _argsText = State(initialValue: server.args.joined(separator: "\n"))
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section(loc.t(isNew ? "claude.mcp.addTitle" : "claude.mcp.editTitle")) {
                    TextField(loc.t("claude.mcp.name"), text: $server.name, prompt: Text(verbatim: "my-server"))
                    Picker(loc.t("claude.mcp.transport"), selection: $server.transport) {
                        Text(verbatim: "stdio").tag(McpServer.Transport.stdio)
                        Text(verbatim: "http").tag(McpServer.Transport.http)
                        Text(verbatim: "sse").tag(McpServer.Transport.sse)
                    }
                    .pickerStyle(.segmented)
                }
                switch server.transport {
                case .stdio:
                    Section(loc.t("claude.mcp.stdioSection")) {
                        TextField(loc.t("claude.mcp.command"), text: $server.command, prompt: Text(verbatim: "npx"))
                            .font(.body.monospaced())
                        VStack(alignment: .leading, spacing: 4) {
                            Text(loc.t("claude.mcp.args"))
                            TextEditor(text: $argsText)
                                .font(.body.monospaced())
                                .frame(minHeight: 60, maxHeight: 110)
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
                        }
                    }
                    pairsSection(loc.t("claude.mcp.env"), pairs: $server.env)
                case .http, .sse:
                    Section(loc.t("claude.mcp.remoteSection")) {
                        TextField(loc.t("claude.mcp.url"), text: $server.url, prompt: Text(verbatim: "https://mcp.example.com/mcp"))
                            .font(.body.monospaced())
                        if server.transport == .sse {
                            Text(loc.t("claude.mcp.sseDeprecated"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    pairsSection(loc.t("claude.mcp.headers"), pairs: $server.headers)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button(loc.t("actions.cancel"), role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button(loc.t("claude.mcp.done")) {
                    var result = server
                    result.name = result.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    result.args = argsText
                        .split(separator: "\n", omittingEmptySubsequences: false)
                        .map(String.init)
                        .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                    onSave(result)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(server.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(12)
        }
        .frame(width: 560, height: 520)
    }

    private func pairsSection(_ title: String, pairs: Binding<[ConfigPair]>) -> some View {
        Section(title) {
            ForEach(pairs) { $pair in
                HStack {
                    TextField("", text: $pair.key, prompt: Text(verbatim: "NAME"))
                        .labelsHidden()
                        .font(.body.monospaced())
                        .frame(maxWidth: 180)
                    if SecretMask.looksSecret(key: pair.key, value: pair.value) && !revealed.contains(pair.id) {
                        SecureField("", text: $pair.value)
                            .labelsHidden()
                    } else {
                        TextField("", text: $pair.value, prompt: Text(verbatim: "value"))
                            .labelsHidden()
                            .font(.body.monospaced())
                    }
                    if SecretMask.looksSecret(key: pair.key, value: pair.value) || revealed.contains(pair.id) {
                        Button {
                            if revealed.contains(pair.id) { revealed.remove(pair.id) } else { revealed.insert(pair.id) }
                        } label: {
                            Image(systemName: revealed.contains(pair.id) ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                        .help(loc.t("claude.mcp.reveal"))
                    }
                    Button {
                        pairs.wrappedValue.removeAll { $0.id == pair.id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                }
            }
            Button(loc.t("claude.mcp.addPair")) { pairs.wrappedValue.append(ConfigPair(key: "", value: "")) }
                .controlSize(.small)
        }
    }
}
