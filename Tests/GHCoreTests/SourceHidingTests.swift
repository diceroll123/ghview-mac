import Foundation
import Testing
@testable import GHCore

private func catalog() -> SourceCatalog {
    SourceCatalog.seeded(from: [.user("me"), .org("acme"), .org("beta"), .org("corp")])
}
private func counts(_ pairs: [(String, Int)]) -> [String: SourceCounts] {
    Dictionary(uniqueKeysWithValues: pairs.map { ($0.0, SourceCounts(open: $0.1)) })
}

// MARK: discovery

@Test func discoveryAddsUnknownOrgsHiddenAndFlagged() {
    var c = catalog()
    let added = c.discover(orgs: ["Zed", "acme", "alpha"])
    #expect(added == ["alpha", "Zed"])  // sorted, existing org skipped
    #expect(c.groups[1].sources.map(\.name) == ["acme", "beta", "corp", "alpha", "Zed"])  // into Organizations
    #expect(c.isHidden(.org("alpha")) && c.isHidden(.org("Zed")) && c.newCount == 2)
    #expect(c.discover(orgs: ["Zed", "alpha"]).isEmpty)  // idempotent
}

@Test func discoveryHonorsPolicyAndNeverResurrectsDeletedOrgs() {
    var c = catalog()
    c.settings.newOrgPolicy = .visible
    c.discover(orgs: ["fresh"])
    #expect(!c.isHidden(.org("fresh")) && c.isNew(.org("fresh")))  // visible but flagged
    c.remove([.org("corp")])
    #expect(c.discover(orgs: ["corp"]).isEmpty && !c.contains("corp"))  // deliberately deleted stays deleted
    #expect(c.missingOrgs(for: Viewer(login: "me", orgs: ["corp"])) == ["corp"])  // but can still be re-added by hand
}

@Test func actingOnANewSourceSettlesIt() {
    var c = catalog()
    c.discover(orgs: ["a", "b", "c"])
    c.setHidden([.org("a")], false)  // user shows one
    #expect(!c.isNew(.org("a")) && !c.isHidden(.org("a")))
    c.setHidden([.org("b")], true)  // user confirms hiding another
    #expect(!c.isNew(.org("b")) && c.isHidden(.org("b")))
    #expect(c.isNew(.org("c")) && c.newCount == 1)
    c.markAllSeen()
    #expect(c.newCount == 0 && c.isHidden(.org("c")))  // seen, still hidden
}

// MARK: auto-hide

@Test func autoHideHidesEmptySourcesOnlyWhenEnabled() {
    var c = catalog()
    let n = counts([("me", 3), ("acme", 0), ("beta", 5), ("corp", 0)])
    c.updateAutoHidden(counts: n)
    #expect(c.hiddenCount == 0)  // off by default
    c.settings.autoHideEmpty = true
    c.updateAutoHidden(counts: n)
    #expect(c.visibleSources.map(\.name) == ["me", "beta"] && c.isAutoHidden(.org("acme")))
    c.settings.autoHideEmpty = false
    c.updateAutoHidden(counts: n)
    #expect(c.hiddenCount == 0)
}

@Test func autoHideLeavesUnknownFailedSelectedAndForceShownSources() {
    var c = catalog()
    c.settings.autoHideEmpty = true
    var n = counts([("me", 0), ("acme", 0), ("beta", 0)])  // corp has no counts yet
    n["acme"] = SourceCounts(error: "SAML")  // failed lookups are not "empty"
    c.setHidden([.org("beta")], false)  // explicitly shown
    c.updateAutoHidden(counts: n, keeping: ["me"])  // currently selected
    #expect(c.autoHidden.isEmpty)  // nothing qualified
    c.updateAutoHidden(counts: counts([("me", 0), ("acme", 0), ("beta", 0), ("corp", 0)]))
    #expect(c.isAutoHidden(.user("me")) && c.isAutoHidden(.org("acme")) && c.isAutoHidden(.org("corp")))
    #expect(!c.isHidden(.org("beta")))  // forceShown survives the rule
}

@Test func autoHideNeverBlanksTheSidebar() {
    var c = catalog()
    c.settings.autoHideEmpty = true
    c.updateAutoHidden(counts: counts([("me", 0), ("acme", 0), ("beta", 0), ("corp", 0)]))
    #expect(c.autoHidden.isEmpty && c.visibleSources.count == 4)  // would hide everything, so hides nothing
    c.setHidden([.org("corp")], true)  // hand-hidden ones are not part of the "everyone" test
    c.updateAutoHidden(counts: counts([("me", 0), ("acme", 0), ("beta", 0), ("corp", 0)]))
    #expect(c.autoHidden.isEmpty)
    c.updateAutoHidden(counts: counts([("me", 4), ("acme", 0), ("beta", 0), ("corp", 0)]))
    #expect(c.visibleSources.map(\.name) == ["me"])
}

@Test func showingAnAutoHiddenSourceKeepsItShown() {
    var c = catalog()
    c.settings.autoHideEmpty = true
    let n = counts([("me", 2), ("acme", 0), ("beta", 1), ("corp", 0)])
    c.updateAutoHidden(counts: n)
    #expect(c.isHidden(.org("acme")))
    c.setHidden([.org("acme")], false)  // tick it in the manager
    c.updateAutoHidden(counts: n)  // counts refresh later
    #expect(!c.isHidden(.org("acme")) && c.isHidden(.org("corp")))
    c.setHidden([.org("acme")], true)  // and hiding it again hides it for good
    c.settings.autoHideEmpty = false
    c.updateAutoHidden(counts: n)
    #expect(c.isHidden(.org("acme")))
}

@Test func showAllAndShowOnlyOverrideTheRule() {
    var c = catalog()
    c.settings.autoHideEmpty = true
    let n = counts([("me", 2), ("acme", 0), ("beta", 0), ("corp", 0)])
    c.updateAutoHidden(counts: n)
    c.showAll()
    c.updateAutoHidden(counts: n)
    #expect(c.hiddenCount == 0)
    c.showOnly([.org("acme")])
    c.updateAutoHidden(counts: n)
    #expect(c.visibleSources.map(\.name) == ["acme"])
}

// MARK: persistence

@Test func newFieldsRoundTripButAutoHiddenIsNotSaved() throws {
    var c = catalog()
    c.settings = SourceSettings(newOrgPolicy: .visible, autoHideEmpty: true)
    c.discover(orgs: ["fresh"])
    c.setHidden([.org("acme")], false)
    c.updateAutoHidden(counts: counts([("me", 1), ("acme", 0), ("beta", 0), ("corp", 0), ("fresh", 1)]))
    #expect(!c.autoHidden.isEmpty)
    let suite = UserDefaults(suiteName: "ghview-hide-\(UUID().uuidString)")!
    c.save(to: suite)
    let loaded = try #require(SourceCatalog.load(from: suite))
    #expect(loaded.settings == c.settings && loaded.newlyDiscovered == c.newlyDiscovered && loaded.forceShown == c.forceShown)
    #expect(loaded.autoHidden.isEmpty)  // recomputed from counts at launch instead
}

@Test func catalogsSavedBeforeTheseFieldsStillLoad() throws {
    let json = #"{"groups":[{"id":"\#(UUID().uuidString)","name":"G","isCollapsed":false,"sources":[{"org":{"_0":"a"}}]},],"hidden":["a"]}"#
        .replacingOccurrences(of: "},]", with: "}]")
    let c = try JSONDecoder().decode(SourceCatalog.self, from: Data(json.utf8))
    #expect(c.isHidden(.org("a")) && c.settings == SourceSettings() && c.newCount == 0 && c.forceShown.isEmpty)
}

@Test func removeAndReplaceCarryTheFlags() throws {
    var c = catalog()
    c.discover(orgs: ["fresh"])
    try c.replace(.org("fresh"), with: .org("fresh2"))
    #expect(c.isNew(.org("fresh2")) && !c.isNew(.org("fresh")) && c.isHidden(.org("fresh2")))
    c.remove([.org("fresh2")])
    #expect(c.newCount == 0 && c.dismissed.contains("fresh2"))
}
