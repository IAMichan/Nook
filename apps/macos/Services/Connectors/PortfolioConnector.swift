import SwiftUI
import CryptoKit

// Crypto portfolio: public wallet addresses and read-only exchange keys, valued in euros.
//
// Everything here is read-only: checking balances and fetching quotes. Nook never places orders and never transfers funds.

// MARK: - Model

/// A blockchain network on which Nook can track a public address.
enum PortfolioNetwork: String, CaseIterable, Identifiable, Sendable {
    case bitcoin, ethereum, solana, polygon, bnb, avalanche, arbitrum, optimism, base
    case dogecoin, litecoin, tron, xrp, cardano, cosmos, near

    var id: String { rawValue }

    var name: String {
        switch self {
        case .bitcoin: return "Bitcoin"
        case .ethereum: return "Ethereum"
        case .solana: return "Solana"
        case .polygon: return "Polygon"
        case .bnb: return "BNB Chain"
        case .avalanche: return "Avalanche"
        case .arbitrum: return "Arbitrum"
        case .optimism: return "Optimism"
        case .base: return "Base"
        case .dogecoin: return "Dogecoin"
        case .litecoin: return "Litecoin"
        case .tron: return "TRON"
        case .xrp: return "XRP Ledger"
        case .cardano: return "Cardano"
        case .cosmos: return "Cosmos"
        case .near: return "NEAR"
        }
    }

    /// The website whose icon stands for this network.
    var iconDomain: String {
        switch self {
        case .bitcoin: return "bitcoin.org"
        case .ethereum: return "ethereum.org"
        case .solana: return "solana.com"
        case .polygon: return "polygon.technology"
        case .bnb: return "bnbchain.org"
        case .avalanche: return "avax.network"
        case .arbitrum: return "arbitrum.io"
        case .optimism: return "optimism.io"
        case .base: return "base.org"
        case .dogecoin: return "dogecoin.com"
        case .litecoin: return "litecoin.org"
        case .tron: return "tron.network"
        case .xrp: return "xrpl.org"
        case .cardano: return "cardano.org"
        case .cosmos: return "cosmos.network"
        case .near: return "near.org"
        }
    }

    /// The native currency for this network's balance. Ethereum L2s hold ETH.
    var coin: String {
        switch self {
        case .bitcoin: return "BTC"
        case .ethereum, .arbitrum, .optimism, .base: return "ETH"
        case .solana: return "SOL"
        case .polygon: return "POL"
        case .bnb: return "BNB"
        case .avalanche: return "AVAX"
        case .dogecoin: return "DOGE"
        case .litecoin: return "LTC"
        case .tron: return "TRX"
        case .xrp: return "XRP"
        case .cardano: return "ADA"
        case .cosmos: return "ATOM"
        case .near: return "NEAR"
        }
    }

    var placeholder: String {
        switch self {
        case .bitcoin: return "bc1q… or 1… or 3…"
        case .ethereum, .polygon, .bnb, .avalanche, .arbitrum, .optimism, .base: return "0x…"
        case .solana: return "Base58 address"
        case .dogecoin: return "D…"
        case .litecoin: return "ltc1… or L… or M…"
        case .tron: return "T…"
        case .xrp: return "r…"
        case .cardano: return "addr1…"
        case .cosmos: return "cosmos1…"
        case .near: return "name.near or 64 hex characters"
        }
    }

    var isEVM: Bool {
        switch self {
        case .ethereum, .polygon, .bnb, .avalanche, .arbitrum, .optimism, .base: return true
        default: return false
        }
    }

    /// Quick offline validation. Also permits only safe characters, since the address goes into a URL.
    func isPlausible(_ raw: String) -> Bool {
        let a = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let safe = a.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-") }
        guard safe, !a.isEmpty else { return false }
        if isEVM {
            guard a.lowercased().hasPrefix("0x") else { return false }
            let hex = a.dropFirst(2)
            return hex.count == 40 && hex.allSatisfy { $0.isHexDigit }
        }
        switch self {
        case .bitcoin:
            if a.lowercased().hasPrefix("bc1") { return a.count >= 14 && a.count <= 90 }
            return (a.hasPrefix("1") || a.hasPrefix("3")) && a.count >= 25 && a.count <= 34
        case .dogecoin:
            return (a.hasPrefix("D") || a.hasPrefix("A")) && a.count >= 25 && a.count <= 34
        case .litecoin:
            if a.lowercased().hasPrefix("ltc1") { return a.count >= 26 && a.count <= 90 }
            return (a.hasPrefix("L") || a.hasPrefix("M")) && a.count >= 25 && a.count <= 34
        case .solana:
            return a.count >= 32 && a.count <= 44
        case .tron:
            return a.hasPrefix("T") && a.count == 34
        case .xrp:
            return a.hasPrefix("r") && a.count >= 25 && a.count <= 35
        case .cardano:
            return a.lowercased().hasPrefix("addr1") && a.count >= 50
        case .cosmos:
            return a.hasPrefix("cosmos1") && a.count == 45
        case .near:
            if a.count == 64 { return a.allSatisfy { $0.isHexDigit && !$0.isUppercase } }
            return a.count >= 5 && a.count <= 64 && a.contains(".")
        default:
            return false
        }
    }
}

/// A public address on a network. Public, so it may be stored in UserDefaults.
struct PortfolioWallet: Identifiable, Hashable, Sendable {
    let network: PortfolioNetwork
    let address: String

    var id: String { "wallet.\(network.rawValue).\(address)" }

    /// "Ethereum 0x12ab…9f3c"
    var label: String {
        let short = address.count > 14 ? "\(address.prefix(6))…\(address.suffix(4))" : address
        return "\(network.name) \(short)"
    }
}

/// An exchange where Nook reads balances with a read-only key.
enum PortfolioExchange: String, CaseIterable, Identifiable, Sendable {
    case binance, okx, bybit, kraken, coinbase

    var id: String { rawValue }
    var sourceID: String { "exchange.\(rawValue)" }

    var name: String {
        switch self {
        case .binance: return "Binance"
        case .okx: return "OKX"
        case .bybit: return "Bybit"
        case .kraken: return "Kraken"
        case .coinbase: return "Coinbase"
        }
    }

    var needsPassphrase: Bool { self == .okx }

    /// The website whose icon stands for this exchange.
    var iconDomain: String {
        switch self {
        case .binance: return "binance.com"
        case .okx: return "okx.com"
        case .bybit: return "bybit.com"
        case .kraken: return "kraken.com"
        case .coinbase: return "coinbase.com"
        }
    }

    var keyLabel: String { self == .coinbase ? tr("portfolio.exchange.coinbaseKeyLabel") : tr("portfolio.exchange.apiKey") }
    var secretLabel: String { self == .coinbase ? tr("portfolio.exchange.coinbaseSecretLabel") : tr("portfolio.exchange.apiSecret") }

    /// Instructions for creating a key with read-only permissions.
    var help: String {
        switch self {
        case .binance: return tr("portfolio.exchange.help.binance")
        case .okx: return tr("portfolio.exchange.help.okx")
        case .bybit: return tr("portfolio.exchange.help.bybit")
        case .kraken: return tr("portfolio.exchange.help.kraken")
        case .coinbase: return tr("portfolio.exchange.help.coinbase")
        }
    }

    /// Keychain account name, e.g. "connector.portfolio.okx.passphrase".
    func account(_ field: String) -> String { "connector.portfolio.\(rawValue).\(field)" }
}

/// Holdings for a single currency, aggregated across all wallets and exchanges.
struct PortfolioHolding: Identifiable, Equatable, Sendable {
    let symbol: String
    var amount: Double
    /// Price in EUR; nil if no price could be found.
    var priceEUR: Double?
    /// 24-hour percentage change; nil if unknown.
    var change24h: Double?
    /// Closing prices of the last 7 days in EUR, oldest first. Empty if unknown.
    var sparkline: [Double] = []

    var id: String { symbol }
    var valueEUR: Double { amount * (priceEUR ?? 0) }
}

// MARK: - Connector

@MainActor
final class PortfolioConnector: ObservableObject, ContextSource {
    let id = "portfolio"
    let title = "Portfolio"
    let symbol = "bitcoinsign.circle"
    var accent: Color { NookTheme.amber }
    var refreshInterval: TimeInterval { 300 }

    @Published private(set) var status = ConnectorStatus()
    /// Sorted by value, highest first.
    @Published private(set) var holdings: [PortfolioHolding] = []
    @Published private(set) var totalEUR: Double = 0
    @Published private(set) var wallets: [PortfolioWallet] = []
    @Published private(set) var configuredExchanges: Set<PortfolioExchange> = []
    /// Error per source (key: `PortfolioWallet.id` or `PortfolioExchange.sourceID`). A failing source does not affect the rest.
    @Published private(set) var sourceErrors: [String: String] = [:]
    @Published private(set) var isRefreshing = false

    private static let walletsKey = "connector.portfolio.wallets"
    /// A change arrived while fetching: refresh once more afterwards.
    private var refreshAgain = false

    init() {
        wallets = Self.loadWallets()
        configuredExchanges = Set(PortfolioExchange.allCases.filter { Self.credentials(for: $0) != nil })
    }

    var isActive: Bool {
        (!wallets.isEmpty || !configuredExchanges.isEmpty) && ConnectorToggle.isOn(id)
    }

    // MARK: - Settings

    /// Adds a public address. Returns an error message, or nil on success.
    @discardableResult
    func addWallet(network: PortfolioNetwork, address raw: String) -> String? {
        let address = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard network.isPlausible(address) else { return "This does not look like a valid \(network.name) address." }
        let wallet = PortfolioWallet(network: network, address: address)
        guard !wallets.contains(wallet) else { return "This address is already added." }
        wallets.append(wallet)
        saveWallets()
        scheduleRefresh()
        return nil
    }

    func removeWallet(_ wallet: PortfolioWallet) {
        wallets.removeAll { $0 == wallet }
        sourceErrors[wallet.id] = nil
        saveWallets()
        scheduleRefresh()
    }

    func isConfigured(_ exchange: PortfolioExchange) -> Bool {
        configuredExchanges.contains(exchange)
    }

    /// Stores keys in the Keychain. Returns an error message, or nil on success.
    @discardableResult
    func saveExchange(_ exchange: PortfolioExchange, key rawKey: String, secret rawSecret: String, passphrase rawPassphrase: String = "") -> String? {
        let strip = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'`"))
        let key = rawKey.trimmingCharacters(in: strip)
        let secret = rawSecret.trimmingCharacters(in: strip)
        let passphrase = rawPassphrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !secret.isEmpty else { return "Enter both the key and the secret." }
        if exchange.needsPassphrase && passphrase.isEmpty { return "\(exchange.name) also requires the passphrase." }
        switch exchange {
        case .kraken where Data(base64Encoded: secret) == nil:
            return "The Kraken secret is not valid base64. Copy it again."
        case .coinbase where PortfolioCoinbaseJWT.privateKey(from: secret) == nil:
            return "Nook cannot read this private key. Use an ECDSA key (not Ed25519) and paste the entire key."
        default:
            break
        }
        var failures: [String] = []
        let values = [("key", key), ("secret", secret), ("passphrase", exchange.needsPassphrase ? passphrase : "")]
        for (field, value) in values {
            let result = Keychain.write(value, account: exchange.account(field))
            if result != 0 { failures.append("Keychain error \(result)") }
        }
        configuredExchanges = Set(PortfolioExchange.allCases.filter { Self.credentials(for: $0) != nil })
        sourceErrors[exchange.sourceID] = nil
        scheduleRefresh()
        return failures.first
    }

    func removeExchange(_ exchange: PortfolioExchange) {
        for field in ["key", "secret", "passphrase"] {
            Keychain.write("", account: exchange.account(field))
        }
        configuredExchanges.remove(exchange)
        sourceErrors[exchange.sourceID] = nil
        scheduleRefresh()
    }

    func error(for wallet: PortfolioWallet) -> String? { sourceErrors[wallet.id] }
    func error(for exchange: PortfolioExchange) -> String? { sourceErrors[exchange.sourceID] }

    private func scheduleRefresh() {
        Task { [weak self] in await self?.refresh() }
    }

    private static func loadWallets() -> [PortfolioWallet] {
        guard let data = UserDefaults.standard.data(forKey: walletsKey),
              let stored = try? JSONDecoder().decode([StoredWallet].self, from: data) else { return [] }
        // Skip an unknown network (from a newer version) instead of losing the entire list.
        return stored.compactMap { item in
            PortfolioNetwork(rawValue: item.network).map { PortfolioWallet(network: $0, address: item.address) }
        }
    }

    private func saveWallets() {
        let stored = wallets.map { StoredWallet(network: $0.network.rawValue, address: $0.address) }
        if let data = try? JSONEncoder().encode(stored) {
            UserDefaults.standard.set(data, forKey: Self.walletsKey)
        }
    }

    private static func credentials(for exchange: PortfolioExchange) -> PortfolioCredentials? {
        guard let key = Keychain.read(exchange.account("key")), !key.isEmpty,
              let secret = Keychain.read(exchange.account("secret")), !secret.isEmpty else { return nil }
        let passphrase = Keychain.read(exchange.account("passphrase")) ?? ""
        if exchange.needsPassphrase && passphrase.isEmpty { return nil }
        return PortfolioCredentials(exchange: exchange, key: key, secret: secret, passphrase: passphrase)
    }

    // MARK: - Fetching

    func refresh() async {
        guard isActive else {
            holdings = []
            totalEUR = 0
            sourceErrors = [:]
            status = ConnectorStatus()
            return
        }
        if isRefreshing {
            refreshAgain = true
            return
        }
        isRefreshing = true
        repeat {
            refreshAgain = false
            await performRefresh()
        } while refreshAgain && isActive
        isRefreshing = false
    }

    private func performRefresh() async {
        if status.updated == nil { status.state = .loading }

        var sources: [PortfolioSource] = wallets.map { .wallet($0) }
        for exchange in PortfolioExchange.allCases where configuredExchanges.contains(exchange) {
            if let credentials = Self.credentials(for: exchange) { sources.append(.exchange(credentials)) }
        }

        let results = await PortfolioFetch.balances(for: sources)

        var amounts: [String: Double] = [:]
        var errors: [String: String] = [:]
        var errorItems: [ConnectorItem] = []
        for source in sources {
            guard let result = results.first(where: { $0.sourceID == source.id }) else { continue }
            if let message = result.error {
                errors[source.id] = message
                errorItems.append(ConnectorItem(id: "error.\(source.id)", title: source.label, subtitle: message, tone: .bad))
            } else {
                for balance in result.balances where balance.amount > 0 {
                    amounts[balance.symbol.uppercased(), default: 0] += balance.amount
                }
            }
        }

        var book = PortfolioPriceBook()
        var priceError: String?
        if !amounts.isEmpty {
            do {
                book = try await PortfolioPrices.fetch(amounts: amounts)
            } catch {
                priceError = "Prices could not be fetched: \(error.localizedDescription)"
            }
        }

        var list: [PortfolioHolding] = []
        for (symbol, amount) in amounts {
            let price = book.priceEUR(symbol)
            var holding = PortfolioHolding(symbol: symbol, amount: amount, priceEUR: price, change24h: book.change[symbol])
            if book.eurPerUSD > 0, let history = book.history[symbol] {
                holding.sparkline = history.map { $0 * book.eurPerUSD }
            }
            // Dust (less than one cent) is omitted; coins without a price remain visible.
            if price == nil || holding.valueEUR >= 0.01 { list.append(holding) }
        }
        list.sort { lhs, rhs in
            lhs.valueEUR != rhs.valueEUR ? lhs.valueEUR > rhs.valueEUR : lhs.symbol < rhs.symbol
        }

        holdings = list
        totalEUR = list.reduce(0) { $0 + $1.valueEUR }
        sourceErrors = errors

        var next = ConnectorStatus()
        next.updated = Date()
        if !sources.isEmpty && errors.count == sources.count {
            next.state = .error(errors.values.sorted().first ?? "Nothing fetched.")
            next.headline = tr("connector.notYetFetched")
        } else {
            next.state = .ok
            next.headline = PortfolioFormat.eur(totalEUR)
        }
        var detail = "\(list.count) \(list.count == 1 ? "coin" : "coins") · \(sources.count) \(sources.count == 1 ? "source" : "sources")"
        if !errors.isEmpty { detail += " · \(errors.count) unreachable" }
        if let priceError = priceError { detail += " · \(priceError)" }
        next.detail = detail
        next.items = list.prefix(5).map { holding in
            ConnectorItem(
                id: "holding.\(holding.symbol)",
                title: "\(holding.symbol) · \(holding.priceEUR == nil ? "no price" : PortfolioFormat.eur(holding.valueEUR))",
                subtitle: PortfolioFormat.subtitle(holding),
                tone: Self.tone(holding.change24h)
            )
        } + errorItems
        status = next
    }

    private static func tone(_ change: Double?) -> ConnectorTone {
        guard let change = change else { return .neutral }
        return change >= 0 ? .good : .bad
    }

    // MARK: - Brain Context

    func contextLines() -> [String] {
        guard isActive, status.updated != nil else { return [] }
        var lines: [String] = []
        let time = status.updated.map(PortfolioFormat.time) ?? ""
        lines.append("Crypto portfolio (read-only, prices \(time)): total \(PortfolioFormat.eur(totalEUR))")
        for holding in holdings.filter({ $0.priceEUR != nil }).prefix(5) {
            lines.append("- \(PortfolioFormat.line(holding))")
        }
        if !sourceErrors.isEmpty {
            lines.append("- Not fetched: \(failedLabels().joined(separator: ", "))")
        }
        return lines
    }

    private func failedLabels() -> [String] {
        var labels: [String] = []
        for wallet in wallets where sourceErrors[wallet.id] != nil { labels.append(wallet.label) }
        for exchange in PortfolioExchange.allCases where sourceErrors[exchange.sourceID] != nil { labels.append(exchange.name) }
        return labels
    }

    /// Full overview for the tool.
    func overview() -> String {
        guard isActive else { return "No portfolio configured (Settings › Connectors › Portfolio)." }
        guard let updated = status.updated else { return "The portfolio has not been fetched yet." }
        let exchangeNames = PortfolioExchange.allCases.filter { configuredExchanges.contains($0) }.map { $0.name }
        let exchangeText = exchangeNames.isEmpty ? "none" : exchangeNames.joined(separator: ", ")
        var lines: [String] = []
        lines.append("Total: \(PortfolioFormat.eur(totalEUR)) (prices as of \(PortfolioFormat.time(updated)), via Coinbase, in EUR)")
        lines.append("Sources: \(wallets.count) \(wallets.count == 1 ? "wallet" : "wallets"), exchanges: \(exchangeText)")
        if holdings.isEmpty { lines.append("No balance found.") }
        for holding in holdings.prefix(40) {
            let trend = holding.sparkline.count > 1 ? " | 7d: " + holding.sparkline.map { PortfolioFormat.eur($0) }.joined(separator: " → ") : ""
            lines.append("- \(PortfolioFormat.line(holding))\(trend)")
        }
        if holdings.count > 40 { lines.append("… and \(holdings.count - 40) more smaller positions.") }
        for wallet in wallets {
            if let message = sourceErrors[wallet.id] { lines.append("Error for \(wallet.label): \(message)") }
        }
        for exchange in PortfolioExchange.allCases {
            if let message = sourceErrors[exchange.sourceID] { lines.append("Error for \(exchange.name): \(message)") }
        }
        return lines.joined(separator: "\n")
    }

    var tools: [ToolSpec] {
        [
            ToolSpec(
                name: "portfolio_overview",
                description: "Returns the user's crypto portfolio: total value in EUR, amount per coin, value, 24-hour change and 7-day price trend, plus sources that were unreachable. Read-only: Nook cannot trade or transfer funds.",
                schema: ["type": "object", "properties": [String: Any](), "required": [String]()],
                kind: .read,
                summarize: { _ in "Read portfolio" },
                tag: { _ in ("", .neutral) },
                run: { [weak self] _ in
                    guard let self = self else { return "Portfolio is not available." }
                    let stale = Date().timeIntervalSince(self.status.updated ?? .distantPast) > 600
                    if self.isActive && stale { await self.refresh() }
                    return self.overview()
                }
            )
        ]
    }
}

private struct StoredWallet: Codable {
    let network: String
    let address: String
}

// MARK: - Formatting

enum PortfolioFormat {
    private static let dutch = Locale(identifier: "nl_NL")

    /// "€ 1.234,56", from one thousand without cents.
    static func eur(_ value: Double) -> String {
        let maximum = abs(value) >= 1000 ? 0 : (abs(value) >= 1 || value == 0 ? 2 : 4)
        let minimum = abs(value) < 1000 && abs(value) >= 1 ? 2 : 0
        let formatter = NookDates.cached("eur|\(minimum)|\(maximum)") { () -> NumberFormatter in
            let formatter = NumberFormatter()
            formatter.locale = dutch
            formatter.numberStyle = .currency
            formatter.currencyCode = "EUR"
            formatter.minimumFractionDigits = minimum
            formatter.maximumFractionDigits = maximum
            return formatter
        }
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "€ %.2f", value)
    }

    /// "+2,3%"
    static func percent(_ value: Double) -> String {
        return (percentFormatter.string(from: NSNumber(value: value)) ?? String(format: "%+.1f", value)) + "%"
    }

    /// "0,12345678", "1,2345" or "12.345"
    static func amount(_ value: Double) -> String {
        let maximum = value >= 1000 ? 0 : (value >= 1 ? 4 : 8)
        let formatter = NookDates.cached("amount|\(maximum)") { () -> NumberFormatter in
            let formatter = NumberFormatter()
            formatter.locale = dutch
            formatter.numberStyle = .decimal
            formatter.minimumFractionDigits = 0
            formatter.maximumFractionDigits = maximum
            return formatter
        }
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    static func time(_ date: Date) -> String {
        NookDates.formatter("HH:mm").string(from: date)
    }

    private static let percentFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = dutch
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 1
        formatter.maximumFractionDigits = 1
        formatter.positivePrefix = "+"
        return formatter
    }()

    /// "0,1234 BTC · 24h +2,3%"
    static func subtitle(_ holding: PortfolioHolding) -> String {
        var text = "\(amount(holding.amount)) \(holding.symbol)"
        if let change = holding.change24h { text += " · 24h \(percent(change))" }
        return text
    }

    /// "BTC: 0,1234 ≈ € 5.000 (24h +2,3%)"
    static func line(_ holding: PortfolioHolding) -> String {
        var text = "\(holding.symbol): \(amount(holding.amount))"
        text += holding.priceEUR == nil ? " (no price)" : " ≈ \(eur(holding.valueEUR))"
        if let change = holding.change24h { text += " (24h \(percent(change)))" }
        return text
    }
}

// MARK: - Sparkline

/// 7-day price line: mint when rising, coral when falling.
struct PortfolioSparkline: View {
    let prices: [Double]
    var lineWidth: CGFloat = 1.5

    private var isUp: Bool {
        guard let first = prices.first, let last = prices.last else { return true }
        return last >= first
    }

    var body: some View {
        GeometryReader { geometry in
            Path { path in
                guard prices.count > 1, let low = prices.min(), let high = prices.max() else { return }
                let inset = lineWidth / 2
                let width = geometry.size.width
                let height = max(geometry.size.height - lineWidth, 0)
                let span = high - low
                let step = width / CGFloat(prices.count - 1)
                for (index, price) in prices.enumerated() {
                    let ratio = span > 0 ? CGFloat((price - low) / span) : 0.5
                    let point = CGPoint(x: CGFloat(index) * step, y: inset + height * (1 - ratio))
                    if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
            }
            .stroke(isUp ? NookTheme.mint : NookTheme.coral,
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
        }
        .accessibilityElement()
        .accessibilityLabel(prices.count > 1 ? (isUp ? "7-day price: up" : "7-day price: down") : "No price history")
    }
}

// MARK: - Sources

private struct PortfolioCredentials: Sendable {
    let exchange: PortfolioExchange
    let key: String
    let secret: String
    let passphrase: String
}

private enum PortfolioSource: Sendable {
    case wallet(PortfolioWallet)
    case exchange(PortfolioCredentials)

    var id: String {
        switch self {
        case .wallet(let wallet): return wallet.id
        case .exchange(let credentials): return credentials.exchange.sourceID
        }
    }

    var label: String {
        switch self {
        case .wallet(let wallet): return wallet.label
        case .exchange(let credentials): return credentials.exchange.name
        }
    }
}

private struct PortfolioBalance: Sendable {
    let symbol: String
    let amount: Double
}

private struct PortfolioFetchResult: Sendable {
    let sourceID: String
    var balances: [PortfolioBalance] = []
    var error: String?
}

/// Small JSON helper on top of `ConnectorHTTP.session`, including service error messages.
private enum PortfolioHTTP {
    static func get(_ url: URL, headers: [String: String] = [:]) async throws -> Any {
        var request = URLRequest(url: url)
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        return try await send(request)
    }

    static func post(_ url: URL, json body: Any) async throws -> Any {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(request)
    }

    static func send(_ original: URLRequest) async throws -> Any {
        var request = original
        if request.value(forHTTPHeaderField: "Accept") == nil {
            request.setValue("application/json", forHTTPHeaderField: "Accept")
        }
        request.setValue("Nook", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await ConnectorHTTP.session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        guard (200..<300).contains(code) else {
            let reason = serviceMessage(json).map { ": \($0)" } ?? "."
            switch code {
            case 401, 403: throw NookError("The key was rejected (\(code))\(reason)")
            case 404: throw NookError("Not found (404)\(reason)")
            case 429: throw NookError("Too many requests. Nook will try again later.")
            default: throw NookError("The service returned an error (\(code))\(reason)")
            }
        }
        guard let result = json else { throw NookError("Unexpected response from the service.") }
        return result
    }

    /// Error message that exchanges return in their payload, kept brief.
    private static func serviceMessage(_ json: Any?) -> String? {
        guard let object = json as? [String: Any] else { return nil }
        var candidates: [Any?] = [object["msg"], object["retMsg"], object["message"], object["error_message"]]
        if let list = object["error"] as? [Any] { candidates.append(list.first) } else { candidates.append(object["error"]) }
        for candidate in candidates {
            if let text = candidate as? String, !text.isEmpty { return String(text.prefix(160)) }
        }
        return nil
    }
}

private enum PortfolioJSON {
    static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    /// Whole numbers as text (yoctoNEAR, wei) without overflowing Double.
    static func bigDecimal(_ text: String) -> Double? {
        guard !text.isEmpty, text.allSatisfy({ $0.isNumber }) else { return nil }
        return text.reduce(0.0) { $0 * 10 + Double($1.wholeNumberValue ?? 0) }
    }

    static func hex(_ text: String) -> Double? {
        let digits = text.lowercased().hasPrefix("0x") ? String(text.dropFirst(2)) : text
        if digits.isEmpty { return 0 }
        var result = 0.0
        for character in digits {
            guard let digit = character.hexDigitValue else { return nil }
            result = result * 16 + Double(digit)
        }
        return result
    }

    static func url(_ text: String) throws -> URL {
        guard let url = URL(string: text) else { throw NookError("Invalid address.") }
        return url
    }
}

private enum PortfolioFetch {
    static func balances(for sources: [PortfolioSource]) async -> [PortfolioFetchResult] {
        await withTaskGroup(of: PortfolioFetchResult.self, returning: [PortfolioFetchResult].self) { group in
            for source in sources {
                group.addTask { await PortfolioFetch.fetch(source) }
            }
            var results: [PortfolioFetchResult] = []
            for await result in group { results.append(result) }
            return results
        }
    }

    private static func fetch(_ source: PortfolioSource) async -> PortfolioFetchResult {
        var result = PortfolioFetchResult(sourceID: source.id)
        do {
            switch source {
            case .wallet(let wallet): result.balances = try await PortfolioWallets.fetch(wallet)
            case .exchange(let credentials): result.balances = try await PortfolioExchanges.fetch(credentials)
            }
        } catch {
            result.error = error.localizedDescription
        }
        return result
    }
}

// MARK: - Wallets (public APIs, no key required)

private enum PortfolioWallets {
    static func fetch(_ wallet: PortfolioWallet) async throws -> [PortfolioBalance] {
        let address = wallet.address
        guard wallet.network.isPlausible(address) else { throw NookError("Invalid address.") }
        switch wallet.network {
        case .bitcoin: return try await bitcoin(address)
        case .dogecoin: return try await blockchair(address, chain: "dogecoin", symbol: "DOGE")
        case .litecoin: return try await blockchair(address, chain: "litecoin", symbol: "LTC")
        // Two public RPCs per chain: the second responds if the first is down or rate-limiting.
        case .ethereum: return try await evm(address, ["https://ethereum-rpc.publicnode.com", "https://cloudflare-eth.com"], symbol: "ETH")
        case .polygon: return try await evm(address, ["https://polygon-bor-rpc.publicnode.com", "https://polygon-rpc.com"], symbol: "POL")
        case .bnb: return try await evm(address, ["https://bsc-dataseed.binance.org", "https://bsc-rpc.publicnode.com"], symbol: "BNB")
        case .avalanche: return try await evm(address, ["https://api.avax.network/ext/bc/C/rpc", "https://avalanche-c-chain-rpc.publicnode.com"], symbol: "AVAX")
        case .arbitrum: return try await evm(address, ["https://arb1.arbitrum.io/rpc", "https://arbitrum-one-rpc.publicnode.com"], symbol: "ETH")
        case .optimism: return try await evm(address, ["https://mainnet.optimism.io", "https://optimism-rpc.publicnode.com"], symbol: "ETH")
        case .base: return try await evm(address, ["https://mainnet.base.org", "https://base-rpc.publicnode.com"], symbol: "ETH")
        case .solana: return try await solana(address)
        case .tron: return try await tron(address)
        case .xrp: return try await xrp(address)
        case .cardano: return try await cardano(address)
        case .cosmos: return try await cosmos(address)
        case .near: return try await near(address)
        }
    }

    private static func bitcoin(_ address: String) async throws -> [PortfolioBalance] {
        let json = try await PortfolioHTTP.get(try PortfolioJSON.url("https://blockchain.info/balance?active=\(address)"))
        guard let object = json as? [String: Any],
              let entry = (object[address] ?? object.values.first) as? [String: Any],
              let satoshi = PortfolioJSON.number(entry["final_balance"]) else { throw NookError("Unexpected response from blockchain.info.") }
        return [PortfolioBalance(symbol: "BTC", amount: satoshi / 1e8)]
    }

    private static func blockchair(_ address: String, chain: String, symbol: String) async throws -> [PortfolioBalance] {
        let json = try await PortfolioHTTP.get(try PortfolioJSON.url("https://api.blockchair.com/\(chain)/dashboards/address/\(address)"))
        guard let data = (json as? [String: Any])?["data"] as? [String: Any],
              let entry = (data[address] ?? data.values.first) as? [String: Any],
              let info = entry["address"] as? [String: Any],
              let units = PortfolioJSON.number(info["balance"]) else { throw NookError("Unexpected response from Blockchair.") }
        return [PortfolioBalance(symbol: symbol, amount: units / 1e8)]
    }

    private static func evm(_ address: String, _ endpoints: [String], symbol: String) async throws -> [PortfolioBalance] {
        var lastError: Error = NookError("No RPC reachable.")
        for endpoint in endpoints {
            do {
                let body: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "eth_getBalance", "params": [address, "latest"]]
                let json = try await PortfolioHTTP.post(try PortfolioJSON.url(endpoint), json: body)
                guard let hex = (json as? [String: Any])?["result"] as? String,
                      let wei = PortfolioJSON.hex(hex) else { throw NookError("Unexpected response from the RPC.") }
                return [PortfolioBalance(symbol: symbol, amount: wei / 1e18)]
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private static func solana(_ address: String) async throws -> [PortfolioBalance] {
        let body: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "getBalance", "params": [address]]
        let json = try await PortfolioHTTP.post(try PortfolioJSON.url("https://api.mainnet-beta.solana.com"), json: body)
        guard let result = (json as? [String: Any])?["result"] as? [String: Any],
              let lamports = PortfolioJSON.number(result["value"]) else { throw NookError("Unexpected response from Solana.") }
        return [PortfolioBalance(symbol: "SOL", amount: lamports / 1e9)]
    }

    private static func tron(_ address: String) async throws -> [PortfolioBalance] {
        let json = try await PortfolioHTTP.get(try PortfolioJSON.url("https://api.trongrid.io/v1/accounts/\(address)"))
        guard let list = (json as? [String: Any])?["data"] as? [[String: Any]] else { throw NookError("Unexpected response from TronGrid.") }
        // An address that never received anything has no account: balance 0.
        let sun = list.first.flatMap { PortfolioJSON.number($0["balance"]) } ?? 0
        return [PortfolioBalance(symbol: "TRX", amount: sun / 1e6)]
    }

    private static func xrp(_ address: String) async throws -> [PortfolioBalance] {
        let body: [String: Any] = ["method": "account_info", "params": [["account": address, "ledger_index": "validated"]]]
        let json = try await PortfolioHTTP.post(try PortfolioJSON.url("https://xrplcluster.com"), json: body)
        guard let result = (json as? [String: Any])?["result"] as? [String: Any] else { throw NookError("Unexpected response from XRPL.") }
        if (result["error"] as? String) == "actNotFound" { return [] }
        guard let account = result["account_data"] as? [String: Any],
              let drops = PortfolioJSON.number(account["Balance"]) else { throw NookError("Unexpected response from XRPL.") }
        return [PortfolioBalance(symbol: "XRP", amount: drops / 1e6)]
    }

    private static func cardano(_ address: String) async throws -> [PortfolioBalance] {
        let json = try await PortfolioHTTP.post(try PortfolioJSON.url("https://api.koios.rest/api/v1/address_info"), json: ["_addresses": [address]])
        guard let list = json as? [[String: Any]] else { throw NookError("Unexpected response from Koios.") }
        let lovelace = list.first.flatMap { PortfolioJSON.number($0["balance"]) } ?? 0
        return [PortfolioBalance(symbol: "ADA", amount: lovelace / 1e6)]
    }

    private static func cosmos(_ address: String) async throws -> [PortfolioBalance] {
        let json = try await PortfolioHTTP.get(try PortfolioJSON.url("https://rest.cosmos.directory/cosmoshub/cosmos/bank/v1beta1/balances/\(address)"))
        guard let balances = (json as? [String: Any])?["balances"] as? [[String: Any]] else { throw NookError("Unexpected response from Cosmos.") }
        let uatom = balances
            .filter { ($0["denom"] as? String) == "uatom" }
            .compactMap { PortfolioJSON.number($0["amount"]) }
            .reduce(0, +)
        return [PortfolioBalance(symbol: "ATOM", amount: uatom / 1e6)]
    }

    private static func near(_ address: String) async throws -> [PortfolioBalance] {
        let body: [String: Any] = [
            "jsonrpc": "2.0", "id": "nook", "method": "query",
            "params": ["request_type": "view_account", "finality": "final", "account_id": address]
        ]
        let json = try await PortfolioHTTP.post(try PortfolioJSON.url("https://rpc.mainnet.near.org"), json: body)
        guard let result = (json as? [String: Any])?["result"] as? [String: Any],
              let text = result["amount"] as? String,
              let yocto = PortfolioJSON.bigDecimal(text) else { throw NookError("Unexpected response from NEAR.") }
        return [PortfolioBalance(symbol: "NEAR", amount: yocto / 1e24)]
    }
}

// MARK: - Exchanges (read-only balance endpoints)

private enum PortfolioExchanges {
    static func fetch(_ credentials: PortfolioCredentials) async throws -> [PortfolioBalance] {
        switch credentials.exchange {
        case .binance: return try await binance(credentials)
        case .okx: return try await okx(credentials)
        case .bybit: return try await bybit(credentials)
        case .kraken: return try await kraken(credentials)
        case .coinbase: return try await coinbase(credentials)
        }
    }

    private static var milliseconds: String { String(Int64(Date().timeIntervalSince1970 * 1000)) }

    private static func hmacSHA256(_ message: Data, key: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key)))
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    /// GET /api/v3/account: balances only.
    private static func binance(_ c: PortfolioCredentials) async throws -> [PortfolioBalance] {
        let query = "omitZeroBalances=true&recvWindow=10000&timestamp=\(milliseconds)"
        let signature = hex(hmacSHA256(Data(query.utf8), key: Data(c.secret.utf8)))
        let url = try PortfolioJSON.url("https://api.binance.com/api/v3/account?\(query)&signature=\(signature)")
        let json = try await PortfolioHTTP.get(url, headers: ["X-MBX-APIKEY": c.key])
        guard let balances = (json as? [String: Any])?["balances"] as? [[String: Any]] else { throw NookError("Unexpected response from Binance.") }
        return balances.compactMap { entry -> PortfolioBalance? in
            guard let asset = entry["asset"] as? String else { return nil }
            let total = (PortfolioJSON.number(entry["free"]) ?? 0) + (PortfolioJSON.number(entry["locked"]) ?? 0)
            return total > 0 ? PortfolioBalance(symbol: asset, amount: total) : nil
        }
    }

    /// GET /api/v5/account/balance: balances only.
    private static func okx(_ c: PortfolioCredentials) async throws -> [PortfolioBalance] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.string(from: Date())
        let path = "/api/v5/account/balance"
        let signature = hmacSHA256(Data("\(timestamp)GET\(path)".utf8), key: Data(c.secret.utf8)).base64EncodedString()
        let json = try await PortfolioHTTP.get(try PortfolioJSON.url("https://www.okx.com\(path)"), headers: [
            "OK-ACCESS-KEY": c.key,
            "OK-ACCESS-SIGN": signature,
            "OK-ACCESS-TIMESTAMP": timestamp,
            "OK-ACCESS-PASSPHRASE": c.passphrase
        ])
        guard let object = json as? [String: Any] else { throw NookError("Unexpected response from OKX.") }
        if let code = object["code"] as? String, code != "0" {
            throw NookError("OKX: \((object["msg"] as? String) ?? "error \(code)")")
        }
        guard let first = (object["data"] as? [[String: Any]])?.first,
              let details = first["details"] as? [[String: Any]] else { throw NookError("Unexpected response from OKX.") }
        return details.compactMap { entry -> PortfolioBalance? in
            guard let currency = entry["ccy"] as? String else { return nil }
            let total = PortfolioJSON.number(entry["cashBal"])
                ?? ((PortfolioJSON.number(entry["availBal"]) ?? 0) + (PortfolioJSON.number(entry["frozenBal"]) ?? 0))
            return total > 0 ? PortfolioBalance(symbol: currency, amount: total) : nil
        }
    }

    /// GET /v5/account/wallet-balance: balances only.
    private static func bybit(_ c: PortfolioCredentials) async throws -> [PortfolioBalance] {
        let timestamp = milliseconds
        let window = "10000"
        let query = "accountType=UNIFIED"
        let signature = hex(hmacSHA256(Data("\(timestamp)\(c.key)\(window)\(query)".utf8), key: Data(c.secret.utf8)))
        let json = try await PortfolioHTTP.get(try PortfolioJSON.url("https://api.bybit.com/v5/account/wallet-balance?\(query)"), headers: [
            "X-BAPI-API-KEY": c.key,
            "X-BAPI-SIGN": signature,
            "X-BAPI-TIMESTAMP": timestamp,
            "X-BAPI-RECV-WINDOW": window
        ])
        guard let object = json as? [String: Any] else { throw NookError("Unexpected response from Bybit.") }
        if let code = PortfolioJSON.number(object["retCode"]), code != 0 {
            throw NookError("Bybit: \((object["retMsg"] as? String) ?? "error \(Int(code))")")
        }
        guard let result = object["result"] as? [String: Any],
              let first = (result["list"] as? [[String: Any]])?.first,
              let coins = first["coin"] as? [[String: Any]] else { throw NookError("Unexpected response from Bybit.") }
        return coins.compactMap { entry -> PortfolioBalance? in
            guard let coin = entry["coin"] as? String, let balance = PortfolioJSON.number(entry["walletBalance"]), balance > 0 else { return nil }
            return PortfolioBalance(symbol: coin, amount: balance)
        }
    }

    /// POST /0/private/Balance: balances only (Kraken also reads via POST).
    private static func kraken(_ c: PortfolioCredentials) async throws -> [PortfolioBalance] {
        guard let secret = Data(base64Encoded: c.secret) else { throw NookError("The Kraken secret is not valid base64.") }
        let nonce = milliseconds
        let path = "/0/private/Balance"
        let body = "nonce=\(nonce)"
        // API-Sign = base64(HMAC-SHA512(pad + SHA256(nonce + body), secret))
        var message = Data(path.utf8)
        message.append(Data(SHA256.hash(data: Data((nonce + body).utf8))))
        let signature = Data(HMAC<SHA512>.authenticationCode(for: message, using: SymmetricKey(data: secret))).base64EncodedString()
        var request = URLRequest(url: try PortfolioJSON.url("https://api.kraken.com\(path)"))
        request.httpMethod = "POST"
        request.httpBody = Data(body.utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(c.key, forHTTPHeaderField: "API-Key")
        request.setValue(signature, forHTTPHeaderField: "API-Sign")
        let json = try await PortfolioHTTP.send(request)
        guard let object = json as? [String: Any] else { throw NookError("Unexpected response from Kraken.") }
        if let errors = object["error"] as? [String], let first = errors.first {
            throw NookError("Kraken: \(first)")
        }
        guard let result = object["result"] as? [String: Any] else { throw NookError("Unexpected response from Kraken.") }
        return result.compactMap { raw, value -> PortfolioBalance? in
            guard let amount = PortfolioJSON.number(value), amount > 0 else { return nil }
            return PortfolioBalance(symbol: krakenSymbol(raw), amount: amount)
        }
    }

    /// Kraken uses custom names (XXBT, ZEUR) and staking suffixes (DOT.S, XBT.F).
    private static func krakenSymbol(_ raw: String) -> String {
        var name = raw.uppercased()
        if let dot = name.firstIndex(of: ".") { name = String(name[..<dot]) }
        let known: [String: String] = [
            "XXBT": "BTC", "XBT": "BTC", "XETH": "ETH", "ETH2": "ETH", "XLTC": "LTC", "XXLM": "XLM",
            "XXMR": "XMR", "XXRP": "XRP", "XZEC": "ZEC", "XXDG": "DOGE", "XDG": "DOGE", "XETC": "ETC",
            "XMLN": "MLN", "XREP": "REP", "ZUSD": "USD", "ZEUR": "EUR", "ZGBP": "GBP", "ZCAD": "CAD", "ZJPY": "JPY"
        ]
        if let mapped = known[name] { return mapped }
        if name.count == 4 && (name.hasPrefix("X") || name.hasPrefix("Z")) { return String(name.dropFirst()) }
        return name
    }

    /// GET /api/v3/brokerage/accounts with a CDP key (ES256-JWT per request): balances only.
    private static func coinbase(_ c: PortfolioCredentials) async throws -> [PortfolioBalance] {
        guard let key = PortfolioCoinbaseJWT.privateKey(from: c.secret) else {
            throw NookError("Nook cannot read this Coinbase private key. Use an ECDSA key.")
        }
        let host = "api.coinbase.com"
        let path = "/api/v3/brokerage/accounts"
        var totals: [String: Double] = [:]
        var cursor: String?
        for _ in 0..<10 {
            var components = URLComponents()
            components.scheme = "https"
            components.host = host
            components.path = path
            var items = [URLQueryItem(name: "limit", value: "250")]
            if let cursor = cursor { items.append(URLQueryItem(name: "cursor", value: cursor)) }
            components.queryItems = items
            guard let url = components.url else { throw NookError("Invalid address.") }
            let jwt = try PortfolioCoinbaseJWT.make(keyName: c.key, key: key, method: "GET", host: host, path: path)
            let json = try await PortfolioHTTP.get(url, headers: ["Authorization": "Bearer \(jwt)"])
            guard let object = json as? [String: Any],
                  let accounts = object["accounts"] as? [[String: Any]] else { throw NookError("Unexpected response from Coinbase.") }
            for account in accounts {
                guard let currency = account["currency"] as? String else { continue }
                let available = PortfolioJSON.number((account["available_balance"] as? [String: Any])?["value"]) ?? 0
                let hold = PortfolioJSON.number((account["hold"] as? [String: Any])?["value"]) ?? 0
                totals[currency, default: 0] += available + hold
            }
            guard (object["has_next"] as? Bool) == true, let next = object["cursor"] as? String, !next.isEmpty else { break }
            cursor = next
        }
        return totals.filter { $0.value > 0 }.map { PortfolioBalance(symbol: $0.key, amount: $0.value) }
    }
}

/// JWT for Coinbase CDP keys: header {alg ES256, kid, nonce, typ}, claims {sub, iss "cdp", nbf, exp +120 s, uri}.
private enum PortfolioCoinbaseJWT {
    /// The EC private key from what the user pasted: PEM (SEC1 or PKCS#8), single-line, or with "\n" escapes.
    static func privateKey(from raw: String) -> P256.Signing.PrivateKey? {
        let text = raw.replacingOccurrences(of: "\\n", with: "\n")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"' \n\r\t"))
        var body = text
        for marker in ["-----BEGIN EC PRIVATE KEY-----", "-----END EC PRIVATE KEY-----",
                       "-----BEGIN PRIVATE KEY-----", "-----END PRIVATE KEY-----"] {
            body = body.replacingOccurrences(of: marker, with: "")
        }
        body = body.components(separatedBy: .whitespacesAndNewlines).joined()
        guard let der = Data(base64Encoded: body) else { return nil }
        if let key = try? P256.Signing.PrivateKey(derRepresentation: der) { return key }
        // SEC1 ECPrivateKey: SEQUENCE { INTEGER 1, OCTET STRING (32 bytes), … }
        let marker = Data([0x02, 0x01, 0x01, 0x04, 0x20])
        if let range = der.range(of: marker), der.count >= range.upperBound + 32 {
            return try? P256.Signing.PrivateKey(rawRepresentation: der.subdata(in: range.upperBound..<(range.upperBound + 32)))
        }
        return nil
    }

    static func make(keyName: String, key: P256.Signing.PrivateKey, method: String, host: String, path: String) throws -> String {
        let now = Int(Date().timeIntervalSince1970)
        let nonce = (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        let header: [String: Any] = ["alg": "ES256", "kid": keyName, "nonce": nonce, "typ": "JWT"]
        let claims: [String: Any] = ["sub": keyName, "iss": "cdp", "nbf": now, "exp": now + 120, "uri": "\(method) \(host)\(path)"]
        let headerData = try JSONSerialization.data(withJSONObject: header, options: [.withoutEscapingSlashes])
        let claimsData = try JSONSerialization.data(withJSONObject: claims, options: [.withoutEscapingSlashes])
        let input = base64URL(headerData) + "." + base64URL(claimsData)
        let signature = try key.signature(for: Data(input.utf8))
        return input + "." + base64URL(signature.rawRepresentation)
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Prices (Coinbase, public, no key required)

private struct PortfolioPriceBook: Sendable {
    /// Euro value of one US dollar.
    var eurPerUSD: Double = 0
    var usd: [String: Double] = [:]
    var change: [String: Double] = [:]
    /// Closing prices in USD, oldest first.
    var history: [String: [Double]] = [:]

    func priceEUR(_ symbol: String) -> Double? {
        guard eurPerUSD > 0, let price = usd[symbol] else { return nil }
        return price * eurPerUSD
    }
}

private struct PortfolioMarket: Sendable {
    let last: Double
    let change: Double?
    let history: [Double]
}

private enum PortfolioPrices {
    static let fiat: Set<String> = ["USD", "EUR", "GBP", "CHF", "CAD", "AUD", "JPY"]
    static let stablecoins: Set<String> = ["USDT", "USDC", "DAI", "BUSD", "FDUSD", "TUSD", "USDP", "PYUSD"]
    /// How many coins receive price details (24 hours, 7 days): the largest. Keeps Coinbase usage friendly.
    static let marketLimit = 20

    static func fetch(amounts: [String: Double]) async throws -> PortfolioPriceBook {
        // A single request returns USD rates for everything Coinbase knows: rates[X] = how much X is one dollar.
        let json = try await PortfolioHTTP.get(try PortfolioJSON.url("https://api.coinbase.com/v2/exchange-rates?currency=USD"))
        guard let rates = ((json as? [String: Any])?["data"] as? [String: Any])?["rates"] as? [String: Any] else {
            throw NookError("Unexpected response from Coinbase.")
        }
        var book = PortfolioPriceBook()
        guard let euro = PortfolioJSON.number(rates["EUR"]), euro > 0 else { throw NookError("No EUR rate from Coinbase.") }
        book.eurPerUSD = euro
        book.usd["USD"] = 1
        for (symbol, value) in rates {
            if let rate = PortfolioJSON.number(value), rate > 0 { book.usd[symbol.uppercased()] = 1 / rate }
        }
        for coin in stablecoins where book.usd[coin] == nil { book.usd[coin] = 1 }

        let candidates = amounts.keys
            .filter { !fiat.contains($0) && !stablecoins.contains($0) && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) } }
            .sorted { lhs, rhs in
                let left = (amounts[lhs] ?? 0) * (book.usd[lhs] ?? 0)
                let right = (amounts[rhs] ?? 0) * (book.usd[rhs] ?? 0)
                return left != right ? left > right : lhs < rhs
            }
            .prefix(marketLimit)

        let markets = await withTaskGroup(of: (String, PortfolioMarket?).self, returning: [String: PortfolioMarket].self) { group in
            for symbol in candidates {
                group.addTask {
                    let market = await PortfolioPrices.market(symbol)
                    return (symbol, market)
                }
            }
            var found: [String: PortfolioMarket] = [:]
            for await (symbol, market) in group {
                if let market = market { found[symbol] = market }
            }
            return found
        }
        for (symbol, market) in markets {
            book.usd[symbol] = market.last
            if let change = market.change { book.change[symbol] = change }
            if !market.history.isEmpty { book.history[symbol] = market.history }
        }
        return book
    }

    /// Latest price and 24h open from /stats, 7 daily closes from /candles. Nil if Coinbase does not support the coin.
    private static func market(_ symbol: String) async -> PortfolioMarket? {
        let base = "https://api.exchange.coinbase.com/products/\(symbol)-USD"
        guard let statsURL = URL(string: "\(base)/stats"),
              let stats = (try? await PortfolioHTTP.get(statsURL)) as? [String: Any],
              let last = PortfolioJSON.number(stats["last"]), last > 0 else { return nil }
        var change: Double?
        if let open = PortfolioJSON.number(stats["open"]), open > 0 { change = (last - open) / open * 100 }
        var history: [Double] = []
        if let candlesURL = URL(string: "\(base)/candles?granularity=86400"),
           let candles = (try? await PortfolioHTTP.get(candlesURL)) as? [[Any]] {
            // [time, low, high, open, close, volume], newest first.
            history = Array(candles.prefix(7).compactMap { $0.count > 4 ? PortfolioJSON.number($0[4]) : nil }.reversed())
        }
        return PortfolioMarket(last: last, change: change, history: history)
    }
}
