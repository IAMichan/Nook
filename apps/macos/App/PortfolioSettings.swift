import SwiftUI

/// Rows for Portfolio in a grouped Form section: public wallet addresses and read-only exchange keys.
/// Addresses are stored in UserDefaults (they are public), keys in the Keychain.
struct PortfolioSettings: View {
    @ObservedObject var portfolio: PortfolioConnector

    @State private var network: PortfolioNetwork = .bitcoin
    @State private var address = ""
    @State private var walletError: String?

    var body: some View {
        Group {
            ForEach(portfolio.wallets) { wallet in
                walletRow(wallet)
            }

            Picker(tr("portfolio.network"), selection: $network) {
                ForEach(PortfolioNetwork.allCases) { item in
                    Text(item.name).tag(item)
                }
            }
            .onChange(of: network) { _, _ in walletError = nil }

            HStack {
                TextField(network.placeholder, text: $address)
                    .font(NookTheme.TextStyle.code)
                    .autocorrectionDisabled()
                    .onSubmit(addWallet)
                Button(tr("button.add"), action: addWallet)
                    .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let message = walletError {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(NookTheme.TextStyle.body)
                    .foregroundStyle(NookTheme.coral)
            }
            Text(tr("portfolio.walletHint"))
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(NookTheme.textSecondary)

            ForEach(PortfolioExchange.allCases) { exchange in
                PortfolioExchangeFields(portfolio: portfolio, exchange: exchange)
            }
            Text(tr("portfolio.exchangeHint"))
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(NookTheme.textSecondary)
        }
    }

    private func walletRow(_ wallet: PortfolioWallet) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                SiteIcon(domain: wallet.network.iconDomain, fallback: "bitcoinsign.circle", size: 18)
                Text(wallet.network.name)
                Text(wallet.address)
                    .font(NookTheme.mono(11))
                    .foregroundStyle(NookTheme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer()
                Button {
                    portfolio.removeWallet(wallet)
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .foregroundStyle(NookTheme.coral)
                }
                .buttonStyle(.borderless)
                .help(tr("portfolio.removeAddress"))
            }
            if let message = portfolio.error(for: wallet) {
                Text(message)
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(NookTheme.coral)
            }
        }
    }

    private func addWallet() {
        if let message = portfolio.addWallet(network: network, address: address) {
            walletError = message
        } else {
            walletError = nil
            address = ""
        }
    }
}

/// Credential fields for a single exchange, collapsed until needed.
private struct PortfolioExchangeFields: View {
    @ObservedObject var portfolio: PortfolioConnector
    let exchange: PortfolioExchange

    @State private var key = ""
    @State private var secret = ""
    @State private var passphrase = ""
    @State private var saveError: String?

    private var canSave: Bool {
        !key.isEmpty && !secret.isEmpty && (!exchange.needsPassphrase || !passphrase.isEmpty)
    }

    var body: some View {
        DisclosureGroup {
            SecureField(exchange.keyLabel, text: $key)
            SecureField(exchange.secretLabel, text: $secret)
            if exchange.needsPassphrase {
                SecureField(tr("portfolio.passphrase"), text: $passphrase)
            }
            HStack {
                Button(tr("button.save"), action: save)
                    .disabled(!canSave)
                if portfolio.isConfigured(exchange) {
                    ConfirmedButton(tr("button.delete"), question: tr("confirm.remove", exchange.name),
                                    detail: tr("confirm.keychain.detail")) {
                        portfolio.removeExchange(exchange)
                        saveError = nil
                    }
                }
                Spacer()
            }
            Text(exchange.help)
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(NookTheme.textSecondary)
            if let message = saveError ?? portfolio.error(for: exchange) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(NookTheme.TextStyle.body)
                    .foregroundStyle(NookTheme.coral)
                    .textSelection(.enabled)
            }
        } label: {
            HStack {
                SiteIcon(domain: exchange.iconDomain, fallback: "building.columns", size: 18)
                Text(exchange.name)
                Spacer()
                if portfolio.isConfigured(exchange) {
                    Label(tr("portfolio.configured"), systemImage: "checkmark.circle.fill")
                        .font(NookTheme.TextStyle.detail)
                        .foregroundStyle(NookTheme.mint)
                }
            }
        }
    }

    private func save() {
        saveError = portfolio.saveExchange(exchange, key: key, secret: secret, passphrase: passphrase)
        if saveError == nil {
            key = ""
            secret = ""
            passphrase = ""
        }
    }
}
