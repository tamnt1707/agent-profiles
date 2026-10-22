import Foundation

/// The state of the delete confirmation: which profile it is about, what it
/// deletes and which measurement is still on its way.
///
/// The state is pure: it never touches the file system. The size of the
/// config folder is measured outside of it and handed back, and the state
/// decides whether the answer still belongs to the open question. An answer
/// of an older question is refused, so the text under the cursor never
/// changes into something that belongs to another profile.
public struct DeleteDialogState: Equatable, Sendable {
    /// The identity of one measurement: the profile it is about and the
    /// question it belongs to.
    public struct Token: Equatable, Sendable {
        /// The slug of the profile the measurement is about.
        public let slug: String
        /// The number of the question the measurement belongs to.
        public let generation: Int

        public init(slug: String, generation: Int) {
            self.slug = slug
            self.generation = generation
        }
    }

    /// The slug of the profile the question is about, `nil` when no question
    /// is open.
    public private(set) var slug: String?
    /// The items the question lists.
    public private(set) var items: [DeleteTarget.Item]
    /// Counts the questions, so the answer of an older one is refused.
    public private(set) var generation: Int

    public init() {
        slug = nil
        items = []
        generation = 0
    }

    /// Opens the question about `slug` and returns the token of the
    /// measurement that it waits for.
    @discardableResult
    public mutating func begin(slug: String, items: [DeleteTarget.Item]) -> Token {
        generation += 1
        self.slug = slug
        self.items = items
        return Token(slug: slug, generation: generation)
    }

    /// `true` while a question is open.
    public var isOpen: Bool { slug != nil }

    /// `true` when the answer of `token` still belongs to the open question.
    ///
    /// The slug and the number of the question must both match: a question
    /// about another profile, or about the same profile but an older one, is
    /// not the one the answer belongs to.
    public func accepts(_ token: Token) -> Bool {
        slug == token.slug && generation == token.generation
    }

    /// Puts the size of the config folder into the list, when the answer
    /// still belongs to the open question.
    ///
    /// Returns `false` when the answer is too late: the question was closed
    /// in the meantime, or it is about another profile now. A folder whose
    /// size is not known is left without one.
    @discardableResult
    public mutating func apply(bytes: Int?, for token: Token) -> Bool {
        guard accepts(token) else { return false }
        items = items.map { item in
            if case .folder(let path, nil) = item {
                return .folder(path: path, bytes: bytes)
            }
            return item
        }
        return true
    }

    /// Closes the question: an answer that comes later belongs to nothing.
    public mutating func cancel() {
        generation += 1
        slug = nil
        items = []
    }
}

/// The sentences of the delete confirmation, in the language of the user.
///
/// The app builds them from its string table. The English and the Vietnamese
/// copies are here for the code that has no table of its own.
public struct DeleteDialogStrings: Equatable, Sendable {
    /// The question. Holds one `%@` placeholder for the name of the profile.
    public var introTemplate: String
    /// The warning under the list.
    public var warning: String
    /// The line of the Keychain entry.
    public var keyText: String
    /// The line of the command. Holds one `%@` placeholder for the command.
    public var commandTemplate: String
    /// The line of the config folder, without its size. Holds one `%@`
    /// placeholder for the path.
    public var folderTemplate: String
    /// The line of the config folder, with its size. Holds two `%@`
    /// placeholders: the path and the size.
    public var folderSizeTemplate: String

    public init(
        introTemplate: String,
        warning: String,
        keyText: String,
        commandTemplate: String,
        folderTemplate: String,
        folderSizeTemplate: String
    ) {
        self.introTemplate = introTemplate
        self.warning = warning
        self.keyText = keyText
        self.commandTemplate = commandTemplate
        self.folderTemplate = folderTemplate
        self.folderSizeTemplate = folderSizeTemplate
    }

    public static let english = DeleteDialogStrings(
        introTemplate: "Delete \"%@\"?",
        warning: "This cannot be undone.",
        keyText: "the API key in the Keychain",
        commandTemplate: "the command %@",
        folderTemplate: "the folder %@ (sessions and history)",
        folderSizeTemplate: "the folder %@ (sessions and history, %@)"
    )

    public static let vietnamese = DeleteDialogStrings(
        introTemplate: "Xóa \"%@\"?",
        warning: "Không thể hoàn tác thao tác này.",
        keyText: "API key trong Keychain",
        commandTemplate: "lệnh %@",
        folderTemplate: "thư mục %@ (sessions và history)",
        folderSizeTemplate: "thư mục %@ (sessions và history, %@)"
    )
}

/// The text of the delete confirmation.
///
/// The text is built from what the state holds, never from the file system:
/// the size of the config folder is measured away from the main thread and
/// handed in. A folder whose size is not known yet is written without one.
public enum DeleteDialogText {
    /// The whole message: the question, the list of what goes away and the
    /// warning under it.
    public static func message(
        name: String,
        items: [DeleteTarget.Item],
        strings: DeleteDialogStrings,
        sizeText: (Int) -> String = { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }
    ) -> String {
        let list = items
            .map { "• " + itemText($0, strings: strings, sizeText: sizeText) }
            .joined(separator: "\n")
        let intro = TemplateFormat.fill(strings.introTemplate, [name])
        return intro + "\n\n" + list + "\n\n" + strings.warning
    }

    /// One line of the list: the key, the command or the folder.
    ///
    /// A folder whose size is not known is written without one, so the line
    /// can be shown before the folder has been measured.
    public static func itemText(
        _ item: DeleteTarget.Item,
        strings: DeleteDialogStrings,
        sizeText: (Int) -> String = { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }
    ) -> String {
        switch item {
        case .key:
            return strings.keyText
        case .command(let name):
            return TemplateFormat.fill(strings.commandTemplate, [name])
        case .folder(let path, let bytes):
            guard let bytes else { return TemplateFormat.fill(strings.folderTemplate, [path]) }
            return TemplateFormat.fill(strings.folderSizeTemplate, [path, sizeText(bytes)])
        }
    }
}
