import XCTest

/// Several accounts per service, without moving the keys of earlier versions.
final class AccountsTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "nook-accounts-tests"

    override func setUp() {
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    func testPrimaryAccountUsesTheOriginalKeychainNames() {
        let registry = AccountRegistry(defaults: defaults)
        let accounts = registry.accounts(for: "github")
        XCTAssertEqual(accounts.count, 1)
        XCTAssertTrue(accounts[0].isPrimary)
        XCTAssertEqual(accounts[0].key("token"), "connector.github.token", "existing keys become the primary account")
    }

    func testAddedAccountsGetTheirOwnKeysAndSurviveRestart() {
        let registry = AccountRegistry(defaults: defaults)
        let work = registry.add(service: "github", label: "Werk")
        let second = registry.add(service: "github", label: "Werk")
        XCTAssertEqual(work.id, "github.werk")
        XCTAssertEqual(second.id, "github.werk2", "ids stay unique")
        XCTAssertEqual(work.key("token"), "connector.github.werk.token")

        let reloaded = AccountRegistry(defaults: defaults)
        XCTAssertEqual(reloaded.accounts(for: "github").map(\.id), ["github", "github.werk", "github.werk2"])
        XCTAssertEqual(reloaded.accounts(for: "notion").map(\.id), ["notion"], "other services are unaffected")
    }

    func testPrimaryCannotBeRemovedButOthersCan() {
        let registry = AccountRegistry(defaults: defaults)
        let work = registry.add(service: "github", label: "Werk")
        registry.remove("github")
        registry.remove(work.id)
        XCTAssertEqual(registry.accounts(for: "github").map(\.id), ["github"])
    }

    func testRenameAndIdentity() {
        let registry = AccountRegistry(defaults: defaults)
        registry.rename("github", to: "Persoonlijk")
        registry.setIdentity("@michan", for: "github")
        let primary = registry.accounts(for: "github")[0]
        XCTAssertEqual(primary.label, "Persoonlijk")
        XCTAssertEqual(primary.identity, "@michan")
        XCTAssertEqual(primary.title(service: "GitHub"), "GitHub · Persoonlijk")
    }

    func testMatchByIdLabelOrIdentity() {
        let registry = AccountRegistry(defaults: defaults)
        let work = registry.add(service: "github", label: "Werk")
        registry.setIdentity("@acme-dev", for: work.id)
        let all = registry.accounts(for: "github")
        XCTAssertEqual(AccountRegistry.match("werk", in: all)?.id, "github.werk")
        XCTAssertEqual(AccountRegistry.match("github.werk", in: all)?.id, "github.werk")
        XCTAssertEqual(AccountRegistry.match("acme-dev", in: all)?.id, "github.werk")
        XCTAssertNil(AccountRegistry.match("private", in: all))
    }

    func testSlug() {
        XCTAssertEqual(AccountRegistry.slug("Zakelijk Account!"), "zakelijk-account")
        XCTAssertEqual(AccountRegistry.slug("Café"), "cafe")
        XCTAssertEqual(AccountRegistry.slug("***"), "account")
    }
}
