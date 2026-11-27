import XCTest

final class MachineBalanceTests: XCTestCase {
    private func place(_ id: String?, _ level: BalanceLevel, active: Int, available: Bool = true) -> MachineBalance.Candidate {
        MachineBalance.Candidate(machineID: id, level: level, active: active, available: available)
    }

    func testTheLeastBusyPlaceForItsWeightWins() {
        // This Mac (Normal, 2 working) against a Preferred machine with 3: 2/2 = 1 against 3/4.
        XCTAssertEqual(MachineBalance.pick([place(nil, .normal, active: 2), place("box", .prefer, active: 3)]), "box")
        // A machine picked less often waits until this Mac has twice its work.
        XCTAssertNil(MachineBalance.pick([place(nil, .normal, active: 1), place("box", .lessOften, active: 1)]))
        XCTAssertEqual(MachineBalance.pick([place(nil, .normal, active: 3), place("box", .lessOften, active: 1)]), "box")
    }

    func testATieStaysOnThisMacThenGoesInOrder() {
        XCTAssertNil(MachineBalance.pick([place("a", .normal, active: 0), place(nil, .normal, active: 0)]))
        XCTAssertEqual(MachineBalance.pick([place(nil, .normal, active: 1), place("a", .normal, active: 0), place("b", .normal, active: 0)]), "a")
    }

    func testManualOnlyAndUnavailablePlacesAreNeverPicked() {
        XCTAssertNil(MachineBalance.pick([place(nil, .manualOnly, active: 0), place("a", .manualOnly, active: 0)]))
        XCTAssertEqual(MachineBalance.pick([place(nil, .manualOnly, active: 0), place("a", .normal, active: 5)]), "a")
        XCTAssertNil(MachineBalance.pick([place(nil, .normal, active: 9), place("a", .prefer, active: 0, available: false)]))
    }

    func testAProjectIsSharedOnceItHasAFolderThere() {
        var box = RemoteMachine(name: "box", host: "me@box")
        XCTAssertTrue(MachineBalance.sharedMachines([box], project: "/Users/me/app").isEmpty)
        box.remember(folder: " ~/code/app ", for: "/Users/me/app/")
        XCTAssertEqual(box.folder(for: "/Users/me/app"), "~/code/app")
        XCTAssertEqual(MachineBalance.sharedMachines([box], project: "/Users/me/app").map(\.name), ["box"])
        XCTAssertEqual(box.balanceLevel, .normal)
    }

    func testOlderAndNewerStoredMachinesStillRead() throws {
        let old = try JSONDecoder().decode(RemoteMachine.self, from: Data(#"{"name":"box","host":"h"}"#.utf8))
        XCTAssertNil(old.balance)
        XCTAssertNil(old.projectFolders)
        let unknown = try JSONDecoder().decode(RemoteMachine.self, from: Data(#"{"name":"box","host":"h","balance":"sometimes"}"#.utf8))
        XCTAssertEqual(unknown.balanceLevel, .normal, "a level from a newer version reads as Normal")
        var machine = RemoteMachine(name: "box", host: "h")
        machine.balance = .prefer
        machine.remember(folder: "/srv/app", for: "/Users/me/app")
        let again = try JSONDecoder().decode(RemoteMachine.self, from: JSONEncoder().encode(machine))
        XCTAssertEqual(again, machine)
    }
}
