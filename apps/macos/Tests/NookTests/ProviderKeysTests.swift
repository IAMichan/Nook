import XCTest

/// Every AI provider's key goes through one store (`ProviderKeys`); a key saved before that, Claude's in
/// `anthropic-api-key` most of all, must still be found. An in-memory store stands in for the Keychain.
final class ProviderKeysTests: XCTestCase {
    private final class Memory {
        var items: [String: String] = [:]
        var refuse = false
        lazy var keys = ProviderKeys(read: { [unowned self] in self.items[$0] },
                                     write: { [unowned self] value, account in
                                         if self.refuse { return -25293 }
                                         self.items[account] = value.isEmpty ? nil : value
                                         return 0
                                     })
    }

    func testClaudesKeyIsStillReadFromItsOldAccount() {
        let memory = Memory()
        // What every version before this one wrote.
        memory.items["anthropic-api-key"] = "sk-ant-api03-saved-before"
        XCTAssertEqual(ProviderKeys.account(provider: "claude"), "anthropic-api-key")
        XCTAssertEqual(memory.keys.key(provider: "claude"), "sk-ant-api03-saved-before")
        XCTAssertTrue(memory.keys.hasKey(provider: "claude"))
    }

    func testOtherProvidersKeepTheirAccounts() {
        let memory = Memory()
        memory.items["openai-api-key"] = "sk-old"
        XCTAssertEqual(ProviderKeys.account(provider: "openai"), "openai-api-key")
        XCTAssertEqual(ProviderKeys.account(provider: "openrouter"), "openrouter-api-key")
        XCTAssertEqual(memory.keys.key(provider: "openai"), "sk-old")
        XCTAssertNil(memory.keys.key(provider: "groq"))
    }

    func testEveryProviderSavesAndRemovesTheSameWay() {
        for provider in ["claude", "openai", "gemini"] {
            let memory = Memory()
            XCTAssertEqual(memory.keys.save("  \"key-\(provider)\"\n", provider: provider), 0)
            XCTAssertEqual(memory.items[ProviderKeys.account(provider: provider)], "key-\(provider)")
            XCTAssertEqual(memory.keys.key(provider: provider), "key-\(provider)")
            memory.keys.save("", provider: provider)
            XCTAssertNil(memory.keys.key(provider: provider))
            XCTAssertTrue(memory.items.isEmpty)
        }
    }

    func testARefusedWriteKeepsTheOldKey() {
        let memory = Memory()
        memory.items["anthropic-api-key"] = "sk-ant-old"
        memory.refuse = true
        XCTAssertNotEqual(memory.keys.save("sk-ant-new", provider: "claude"), 0)
        XCTAssertEqual(memory.keys.key(provider: "claude"), "sk-ant-old")
    }

    func testMaskedAndLooksValid() {
        XCTAssertEqual(ProviderKeys.masked("sk-ant-api03-abcdefgh1234"), "sk-ant-…1234")
        XCTAssertNil(ProviderKeys.masked("short"))
        XCTAssertNil(ProviderKeys.masked(nil))
        XCTAssertTrue(ProviderKeys.looksValid(" sk-ant-abc ", prefix: "sk-ant-"))
        XCTAssertFalse(ProviderKeys.looksValid("sk-abc", prefix: "sk-ant-"))
        XCTAssertFalse(ProviderKeys.looksValid("sk-ant- abc", prefix: "sk-ant-"))
        XCTAssertTrue(ProviderKeys.looksValid("anything", prefix: nil))
        XCTAssertFalse(ProviderKeys.looksValid("", prefix: nil))
    }
}
