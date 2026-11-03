--[[
Purpose: Name und Richtung eines Gleises direkt auf der Node aendern (Konzept 12.4): die Leitstelle fuehrt die Aenderung im Verzeichnis aus, aber nur fuer Gleise der eigenen Anforderung und nur mit aktuellem Stand; die Node zieht nach und bewertet Signale neu.
]]

local t = dofile("tests/lib/t.lua")
local G = dofile("tests/lib/guided.lua")

local function tracks_of(d) return d.node.setup.session().wiz.guided_rows() end

return {
  { "Gleis umbenennen und Richtung wechseln: Verzeichnis und Node stimmen danach ueberein, das Signal folgt der Richtung", function()
    local h, z, d, v, netz = G.setup()
    d.tap(v, "act:signal_waehlen"); d.tap(v, "sel:signal:1")
    d.tap(v, "sel:zuordnung:1")
    d.tap(v, "act:gleis_aendern")
    t.eq(G.screen(d), "4.z.gleis", d.text(v))
    t.contains(d.text(v), "Gleis 1")
    d.type(v, "gleisname", "Hauptgleis")
    d.tap(v, "act:g_richtung"); d.tap(v, "act:g_richtung")        -- Ostbahnhof -> beide -> Westbahnhof
    d.tap(v, "act:g_speichern")
    h.step(3); d.node.render()
    t.eq(G.screen(d), "4.zuordnung", d.text(v) .. v.hint)
    t.eq(netz.track("A0001").name, "Hauptgleis")
    local row = tracks_of(d)[1]
    t.eq(row.name, "Hauptgleis")
    t.eq(row.direction, "Westbahnhof"); t.eq(netz.track("A0001").direction, "Westbahnhof")
    t.eq(row.rev, netz.track("A0001").rev, "der Stand wird mitgefuehrt")
    t.contains(v.hint, "Gleis geaendert")
    t.contains(v.hint, "neu bewerten")
    t.eq(row.signals[1].effect, row.direction, "die Wirkrichtung folgt der eindeutigen Richtung")
  end },
  { "Nur der Name oder nur die Richtung: die jeweils andere Angabe bleibt unberuehrt; ohne Aenderung nichts senden", function()
    local h, z, d, v, netz = G.setup()
    local before = netz.track("A0002").direction
    d.tap(v, "sel:zuordnung:2")
    d.tap(v, "act:gleis_aendern")
    d.type(v, "gleisname", "Gleis Zwei")
    d.tap(v, "act:g_speichern")
    h.step(3); d.node.render()
    t.eq(netz.track("A0002").name, "Gleis Zwei"); t.eq(netz.track("A0002").direction, before)
    d.tap(v, "act:gleis_aendern")
    d.tap(v, "act:g_speichern")
    t.contains(v.hint, "Nichts geaendert")
    t.eq(G.screen(d), "4.zuordnung")
  end },
  { "Doppelter Name und leerer Name werden abgelehnt, die Eingabe bleibt stehen", function()
    local h, z, d, v, netz = G.setup()
    d.tap(v, "sel:zuordnung:2")
    d.tap(v, "act:gleis_aendern")
    d.type(v, "gleisname", "gleis 1")
    d.tap(v, "act:g_speichern")
    h.step(3); d.node.render()
    t.eq(G.screen(d), "4.z.gleis", d.text(v))
    t.contains(v.hint, "gibt es in diesem Bereich schon")
    t.eq(netz.track("A0002").name, "Gleis 2")
    d.type(v, "gleisname", "   ")
    d.tap(v, "act:g_speichern")
    t.contains(v.hint, "Gleisname fehlt")
    d.tap(v, "act:zurueck")
    t.eq(G.screen(d), "4.zuordnung")
  end },
  { "Inzwischen anders geaendert (veralteter Stand): abgelehnt, nichts wird ueberschrieben", function()
    local h, z, d, v, netz = G.setup()
    netz.set_track("A0001", { name = "Zentral umbenannt" })
    d.tap(v, "sel:zuordnung:1")
    d.tap(v, "act:gleis_aendern")
    d.type(v, "gleisname", "Lokal umbenannt")
    d.tap(v, "act:g_speichern")
    h.step(3); d.node.render()
    t.eq(netz.track("A0001").name, "Zentral umbenannt")
    t.ok(v.hint:find("inzwischen") or v.hint:find("Stand"), v.hint)
    t.eq(tracks_of(d)[1].name, "Gleis 1", "lokal bleibt unveraendert")
  end },
  { "Leitstelle: fremde Anforderung, fremdes Gleis, fehlende Angaben und Unsinn werden abgelehnt", function()
    local h, z, d, v, netz = G.setup()
    local role = z.node.roles.zentrale
    local replies = {}
    local real = z.node.reply
    z.node.reply = function(m, status, payload) replies[#replies + 1] = { status = status, payload = payload } return real(m, status, payload) end
    local claim = d.node.setup.session().dir.claim
    local function ask(payload)
      role.on_message(d.node.replace_factory.make("abfrage", "hauptstelle", payload), "ok")
      return replies[#replies]
    end
    local rev = netz.track("A0001").rev
    local other = netz.add_area({ name = "Nord-Sued", ends = { "Nord", "Sued" }, count = 1 })
    local foreign = netz.area(other).tracks[1].id
    t.eq(ask({ kind = "gleis_aendern", claim = "unbekannt-12345", track = "A0001", name = "X", if_rev = rev }).status, "abgelehnt")
    t.eq(ask({ kind = "gleis_aendern", claim = claim, track = foreign, name = "X", if_rev = netz.track(foreign).rev }).status, "abgelehnt", "Gleis einer anderen Anforderung")
    t.eq(ask({ kind = "gleis_aendern", claim = claim, track = "A0001", name = "X" }).status, "abgelehnt", "ohne Stand")
    t.eq(ask({ kind = "gleis_aendern", claim = claim, track = "A0001", if_rev = rev }).status, "abgelehnt", "ohne Aenderung")
    t.eq(ask({ kind = "gleis_aendern", claim = claim, track = "A0001", name = 7, if_rev = rev }).status, "abgelehnt")
    t.eq(ask({ kind = "gleis_aendern", claim = claim, track = "A0001", direction = "Nirgendwo", if_rev = rev }).status, "abgelehnt")
    t.eq(ask({ kind = "gleis_aendern", claim = claim, track = 5, name = "X", if_rev = rev }).status, "abgelehnt")
    t.eq(netz.track("A0001").name, "Gleis 1")
    local ok = ask({ kind = "gleis_aendern", claim = claim, track = "A0001", name = "Neu", if_rev = rev })
    t.eq(ok.status, "ok"); t.eq(ok.payload.track.name, "Neu")
    -- eine verworfene Anforderung darf nichts mehr aendern
    assert(netz.discard_node("N0001"))
    local late = ask({ kind = "gleis_aendern", claim = claim, track = "A0001", name = "Spaet", if_rev = netz.track("A0001").rev })
    t.eq(late.status, "abgelehnt"); t.eq(netz.track("A0001").name, "Neu")
  end },
  { "Leitstelle nicht erreichbar: Meldung, Eingabe bleibt, die Node-Daten aendern sich nicht", function()
    local h, z, d, v, netz = G.setup()
    z.node.handle = function() end
    d.tap(v, "sel:zuordnung:1")
    d.tap(v, "act:gleis_aendern")
    d.type(v, "gleisname", "Ohne Antwort")
    d.tap(v, "act:g_speichern")
    h.step(12); d.node.render()
    t.contains(d.text(v) .. v.hint, "antwortet nicht")
    t.eq(G.screen(d), "4.z.gleis")
    t.eq(tracks_of(d)[1].name, "Gleis 1")
  end },
}
