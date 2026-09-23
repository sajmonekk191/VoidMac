import Testing
@testable import VoidMac

@Test func priorityPutsTheUsersOrderFirstThenClassesThenUnknowns() {
    let order = ["ahri", "leona"]
    #expect(TargetPriority.rank(of: "Ahri", order: order) == 0)
    #expect(TargetPriority.rank(of: "Leona", order: order) == 1)
    #expect(TargetPriority.rank(of: "Jinx", order: order) < TargetPriority.rank(of: "Darius", order: order))
    #expect(TargetPriority.rank(of: "Darius", order: order) < TargetPriority.rank(of: "Malphite", order: order))
    #expect(TargetPriority.rank(of: "", order: order) == TargetPriority.unknownRank)
    #expect(TargetPriority.ordered(["malphite", "jinx", "leona", "zed"], order: order) == ["leona", "jinx", "zed", "malphite"])
}

@Test func rearrangingTheMatchKeepsEveryoneElsesPlace() {
    #expect(TargetPriority.reorder(["jinx", "ahri"], stored: ["ahri", "zed", "jinx"]) == ["jinx", "ahri", "zed"])
    #expect(TargetPriority.reorder(["Kog'Maw"], stored: []) == ["kogmaw"])
}

@Test func championTraitsCoverMissilesClassesAndDisplayNames() throws {
    let ashe = try #require(ChampionCombat.traits(for: "Ashe"))
    #expect(ashe.ranged && ashe.missileSpeed == 2500 && ashe.role == "Marksman" && ashe.defaultPriority == 5)
    let wukong = try #require(ChampionCombat.traits(for: "Wukong"))
    #expect(!wukong.ranged && wukong.projectileSpeed(attackRange: 175) == .infinity)
    #expect(try #require(ChampionCombat.traits(for: "Jinx")).projectileSpeed(attackRange: 525) == 2000)
    let kayle = try #require(ChampionCombat.traits(for: "Kayle"))
    #expect(kayle.projectileSpeed(attackRange: 175) == .infinity && kayle.projectileSpeed(attackRange: 525) == 5000)
    #expect(ChampionCombat.table.count >= 170)
}
