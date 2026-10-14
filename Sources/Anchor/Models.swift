import Foundation
import Observation

// Shared contract. Store.swift, Limits.swift, Usage.swift and the views extend these types.

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser.path
    static let primaryDir = home + "/.claude"            // account that never sets CLAUDE_CONFIG_DIR
    static let anchor = home + "/.claude-anchor"
    static let accounts = anchor + "/accounts"
    static let config = anchor + "/config.json"
    static let routes = anchor + "/routes"                // read by shell/anchor.zsh
    static let usage = anchor + "/usage.json"
}

/// International Code of Signals letters used as account identity.
enum SignalFlag: String, Codable, CaseIterable, Identifiable {
    case a, b, c, d, e, f, g, h, i, j, k, l, m, n, o, p, q, r, s, t, u, v, w, x, y, z
    var id: String { rawValue }
    var letter: String { rawValue.uppercased() }
}

struct Account: Codable, Identifiable, Hashable {
    var id: String            // slug, stable
    var name: String
    var flag: SignalFlag
    var dir: String           // absolute config dir; == Paths.primaryDir for the primary account
    var email: String?
    var plan: String?         // e.g. "pro", "max"
    var pending: Bool = false // created, sign-in not finished

    var isPrimary: Bool { dir == Paths.primaryDir }
    /// Value for CLAUDE_CONFIG_DIR, nil for primary (setting it would change the keychain service name).
    var configDirEnv: String? { isPrimary ? nil : dir }
}

struct Rule: Codable, Identifiable, Hashable {
    var path: String          // absolute folder prefix, no trailing slash
    var accountID: String
    var allowOverflow: Bool = false
    var id: String { path }
}

struct Config: Codable {
    var accounts: [Account] = []
    var rules: [Rule] = []
    var defaultID: String = "primary"
    var overflowThreshold: Double = 90   // percent
    var autoOverflow: Bool = true
    var bell: Bool = false
    var editorIntegration: Bool?              // optional so older config.json still decodes
    var removedNames: [String: String] = [:]  // accountID -> name, for usage history of removed accounts
}

extension Config {
    /// Tolerant of missing keys (hand-edited or older files); `accounts` must exist or the file is treated as corrupt.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accounts = try c.decode([Account].self, forKey: .accounts)
        rules = try c.decodeIfPresent([Rule].self, forKey: .rules) ?? []
        defaultID = try c.decodeIfPresent(String.self, forKey: .defaultID) ?? "primary"
        overflowThreshold = try c.decodeIfPresent(Double.self, forKey: .overflowThreshold) ?? 90
        autoOverflow = try c.decodeIfPresent(Bool.self, forKey: .autoOverflow) ?? true
        bell = try c.decodeIfPresent(Bool.self, forKey: .bell) ?? false
        editorIntegration = try c.decodeIfPresent(Bool.self, forKey: .editorIntegration)
        removedNames = try c.decodeIfPresent([String: String].self, forKey: .removedNames) ?? [:]
    }
}

struct LimitWindow: Codable, Hashable {
    var percent: Double       // 0...100
    var resetsAt: Date?
}

struct Limits: Codable, Hashable {
    var fiveHour: LimitWindow?
    var weekly: LimitWindow?
    var fetchedAt: Date
    var stale: Bool = false   // came from cachedUsageUtilization, not a live fetch
    var error: String?        // user-facing, e.g. "Work's sign-in expired. Sign in again."
    var needsSignIn = false   // error is an expired sign-in, so offer "Sign in again"
    var note: String?         // soft warning shown under the bars, e.g. offline
}

enum GroupBy: String, CaseIterable, Identifiable {
    case account = "Account", project = "Project", model = "Model"
    var id: String { rawValue }
}

struct UsageRow: Identifiable, Hashable {
    var id: String            // group key (accountID / cwd / model)
    var label: String         // display: account name, "~/code/website", "Opus 5.5"
    var accountID: String?    // set when grouping by account (for the flag)
    var tokens: Int           // input + output + cache read + cache write
    var outputTokens: Int
    var cost: Double          // estimated USD
}

@Observable @MainActor
final class AppModel {
    var config = Config()
    var limits: [String: Limits] = [:]      // accountID -> latest
    var usageRows: [UsageRow] = []
    var groupBy: GroupBy = .account { didSet { refreshRows() } }
    var rangeDays: Int = 7 { didSet { refreshRows() } }
    var lastSession: (cwd: String, accountID: String, file: String?)?
    var overflowSuggestion: String?          // account id to continue the last conversation on
    var banner: String?                      // last overflow / error message shown in popover
    var signingIn: Set<String> = []          // accounts with a browser sign-in in progress
    var cliInstalled = true                  // Claude Code CLI found; rechecked each time the popover opens
    var live = true                          // false for snapshot models: never touch real files
    var saveBlocked = false                  // config.json exists but couldn't be backed up; don't overwrite it

    let usage = UsageIndex()

    var accounts: [Account] { config.accounts }
    var active: Account? { config.accounts.first { $0.id == config.defaultID } ?? config.accounts.first }
    func account(_ id: String) -> Account? { config.accounts.first { $0.id == id } }

    func refreshRows() {
        usageRows = usage.rows(by: groupBy, days: rangeDays, accounts: config.accounts, removed: config.removedNames)
        lastSession = usage.lastSession
    }
}
