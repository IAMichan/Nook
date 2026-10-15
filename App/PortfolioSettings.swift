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
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
                    .onSubmit(addWallet)
                Button(tr("button.add"), action: addWallet)
                    .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let message = walletError {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(Color.red)
            }
            Text(tr("portfolio.walletHint"))
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(PortfolioExchange.allCases) { exchange in
                PortfolioExchangeFields(portfolio: portfolio, exchange: exchange)
            }
            Text(tr("portfolio.exchangeHint"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func walletRow(_ wallet: PortfolioWallet) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(wallet.network.name)
                Text(wallet.address)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer()
                Button {
                    portfolio.removeWallet(wallet)
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .foregroundStyle(Color.red)
                }
                .buttonStyle(.borderless)
                .help(tr("portfolio.removeAddress"))
            }
            if let message = portfolio.error(for: wallet) {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(Color.red)
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
                SecureField("Passphrase", text: $passphrase)
            }
            HStack {
                Button(tr("button.save"), action: save)
                    .disabled(!canSave)
                if portfolio.isConfigured(exchange) {
                    Button(tr("button.delete"), role: .destructive) {
                        portfolio.removeExchange(exchange)
                        saveError = nil
                    }
                }
                Spacer()
            }
            Text(exchange.help)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let message = saveError ?? portfolio.error(for: exchange) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(Color.red)
                    .textSelection(.enabled)
            }
        } label: {
            HStack {
                Text(exchange.name)
                Spacer()
                if portfolio.isConfigured(exchange) {
                    Label(tr("portfolio.configured"), systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(Color.green)
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
