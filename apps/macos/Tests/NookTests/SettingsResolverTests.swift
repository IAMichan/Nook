import XCTest

final class SettingsResolverTests: XCTestCase {
    typealias R = SettingsResolver

    private func layers() -> R.Layers {
        var l = R.Layers()
        l.set("cleanup", .string("off"), in: .builtIn)
        l.set("cleanup", .string("custom"), in: .environment)
        l.set("limit", .int(5), in: .builtIn)
        l.set("limit", .int(9), in: .repositoryFile)
        return l
    }

    func testPrecedenceProjectEnvironmentFileBuiltIn() {
        var l = layers()
        XCTAssertEqual(R.resolve("cleanup", l)?.source, .environment)
        XCTAssertEqual(R.resolve("cleanup", l)?.overrides, [.builtIn])
        l.set("cleanup", .string("project"), in: .project)
        let r = R.resolve("cleanup", l)
        XCTAssertEqual(r?.value, .string("project"))
        XCTAssertEqual(r?.source, .project)
        XCTAssertEqual(r?.overrides, [.environment, .builtIn])
        XCTAssertEqual(R.resolve("limit", l)?.source, .repositoryFile)
        XCTAssertNil(R.resolve("missing", l))
    }

    func testOverriddenByWhenViewedFromLowerLayer() {
        var l = layers()
        l.set("cleanup", .string("project"), in: .project)
        XCTAssertEqual(R.resolve("cleanup", l, viewing: .environment)?.overriddenBy, .project)
        XCTAssertNil(R.resolve("cleanup", l, viewing: .project)?.overriddenBy)
        XCTAssertNil(R.resolve("limit", l, viewing: .environment)?.overriddenBy, "environment does not set limit")
    }

    func testProvenance() {
        var l = layers()
        XCTAssertEqual(R.provenance("cleanup", l, at: .environment), .overridden)
        XCTAssertEqual(R.provenance("cleanup", l, at: .project), .inherited(from: .environment))
        XCTAssertEqual(R.provenance("limit", l, at: .project), .inherited(from: .repositoryFile))
        XCTAssertEqual(R.provenance("limit", l, at: .environment), .inherited(from: .repositoryFile))
        l.reset("limit", in: .repositoryFile)
        XCTAssertEqual(R.provenance("limit", l, at: .project), .builtIn)
        XCTAssertNil(R.provenance("missing", l, at: .project))
        XCTAssertEqual(Set([R.Provenance.builtIn, .inherited(from: .project), .overridden, .mixed].map(\.key)),
                       ["builtIn", "inherited", "overridden", "mixed"])
    }

    func testResetIsTheReverseOfSet() {
        var l = layers()
        l.set("cleanup", .string("project"), in: .project)
        let reset = l.resetting("cleanup", in: .project)
        XCTAssertEqual(R.resolve("cleanup", reset)?.source, .environment)
        XCTAssertEqual(R.provenance("cleanup", reset, at: .project), .inherited(from: .environment))
        XCTAssertEqual(R.resolve("cleanup", l)?.source, .project, "original untouched")
    }

    func testMixedAcrossSelectedScopes() {
        var a = layers(), b = layers()
        XCTAssertEqual(R.resolveAcross("cleanup", scopes: [a, b]).provenance, .inherited(from: .environment))
        b.set("cleanup", .string("project"), in: .project)
        let agg = R.resolveAcross("cleanup", scopes: [a, b])
        XCTAssertEqual(agg.provenance, .mixed)
        if case .mixed(let each) = agg { XCTAssertEqual(each.map { $0?.value }, [.string("custom"), .string("project")]) } else { XCTFail() }
        a.set("cleanup", .string("project"), in: .project)
        if case .uniform = R.resolveAcross("cleanup", scopes: [a, b]) {} else { XCTFail("same value from the same layer agrees") }
        XCTAssertEqual(R.resolveAcross("missing", scopes: [a, b]), .unset)
        XCTAssertEqual(R.resolveAcross("x", scopes: []), .unset)
    }

    func testMixedWhenOnlyOneScopeSetsTheKey() {
        var a = R.Layers(), b = R.Layers()
        a.set("k", .bool(true), in: .project)
        XCTAssertEqual(R.resolveAcross("k", scopes: [a, b]).provenance, .mixed)
        b.set("k", .bool(true), in: .environment)
        if case .uniform = R.resolveAcross("k", scopes: [a, b]) {} else { XCTFail() }
    }

    func testSettingValueCodable() throws {
        let value = SettingValue.list([.bool(true), .int(3), .double(1.5), .string("x"), .list([.int(1)])])
        let data = try JSONEncoder().encode(value)
        XCTAssertEqual(try JSONDecoder().decode(SettingValue.self, from: data), value)
        XCTAssertEqual(try JSONDecoder().decode(SettingValue.self, from: Data("true".utf8)), .bool(true))
        XCTAssertEqual(try JSONDecoder().decode(SettingValue.self, from: Data("2".utf8)), .int(2))
        let layers = layers()
        XCTAssertEqual(try JSONDecoder().decode(R.Layers.self, from: JSONEncoder().encode(layers)), layers)
    }

    func testScopeSentenceAndWriteLayer() {
        XCTAssertEqual(ProjectScope.allProjects.writeLayer, .environment)
        XCTAssertEqual(ProjectScope.project(path: "/a").writeLayer, .project)
        XCTAssertEqual(ScopeDescription(project: .allProjects, machineSelected: false, isCheckout: false).connector, .across)
        XCTAssertEqual(ScopeDescription(project: .allProjects, machineSelected: true, isCheckout: false).connector, .on)
        XCTAssertEqual(ScopeDescription(project: .project(path: "/a"), machineSelected: false, isCheckout: true).connector, .on)
    }
}
