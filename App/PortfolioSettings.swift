import SwiftUI

/// Rijen voor het Portfolio in een gegroepeerde Form-sectie: openbare walletadressen en alleen-lezen beurssleutels.
/// Adressen staan in UserDefaults (ze zijn openbaar), sleutels in de Keychain.
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

            Picker("Netwerk", selection: $network) {
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
                Button("Voeg toe", action: addWallet)
                    .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let message = walletError {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(Color.red)
            }
            Text("Alleen openbare adressen: Nook leest het saldo via openbare diensten van het netwerk. Deel nooit je seed phrase of privésleutel.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(PortfolioExchange.allCases) { exchange in
                PortfolioExchangeFields(portfolio: portfolio, exchange: exchange)
            }
            Text("Gebruik sleutels met alleen leesrechten. Nook leest saldo’s en plaatst nooit orders of opnames. Koersen komen van Coinbase en worden in euro getoond.")
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
                .help("Verwijder dit adres")
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

/// Sleutelvelden voor één beurs, ingeklapt tot je ze nodig hebt.
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
                Button("Bewaar", action: save)
                    .disabled(!canSave)
                if portfolio.isConfigured(exchange) {
                    Button("Verwijder", role: .destructive) {
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
                    Label("Ingesteld", systemImage: "checkmark.circle.fill")
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
