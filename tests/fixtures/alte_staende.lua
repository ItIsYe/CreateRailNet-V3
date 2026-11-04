--[[
Purpose: Datenstaende (Inhalt von /crn_data) dreier Nodes, wie aeltere Programmversionen sie geschrieben haben: erste Fassung nach dem Neustart (864193c, 29.10.2026) und der Stand vor dem Netzverzeichnis-Abgleich (0f1bfbc, 03.11.2026). Erzeugt, indem die damalige Programmfassung aus Git ausgecheckt und mit ihrem eigenen Testnetz (Leitstelle, Signal-Node mit zwei Gleisen und drei Signalen, Bahnhof) 120 Sekunden betrieben wurde. tests/test_integrator.lua startet das aktuelle Programm darauf.
Notes: { [Fassung] = { [Node] = { [Pfad] = Dateiinhalt } } }. Nicht von Hand aendern; neue Staende kommen als weitere Fassung dazu.
]]

return {
  -- Erste Fassung nach dem Neustart
  ["864193c"] = {
    ["bahnhof"] = {
      ["crn_data/clock.lua"] = "-- crn 60690722 24\
{[\"boots\"]=1,[\"t\"]=120,}",
      ["crn_data/clock.lua.prev"] = "-- crn 59aa06f8 23\
{[\"boots\"]=1,[\"t\"]=90,}",
      ["crn_data/config.lua"] = "-- crn 36f9c3a6 568\
{[\"devices\"]={[\"station1\"]={[\"device\"]=\"Create_Station_1\",[\"kind\"]=\"station\",},},[\"junction\"]={[\"conflicts\"]={},[\"connections\"]={},[\"moves\"]={},},[\"network\"]={[\"central_id\"]=\"hauptstelle\",[\"name\"]=\"Testnetz\",},[\"node\"]={[\"id\"]=\"bahnhof\",[\"name\"]=\"bahnhof\",[\"roles\"]={[1]=\"passagierbahnhof\",},},[\"registration_station\"]=\"station1\",[\"revision\"]=1,[\"status\"]=\"aktiv\",[\"tests\"]={},[\"tracks\"]={[\"gleis1\"]={[\"direction\"]=\"beide\",[\"name\"]=\"Gleis 1\",[\"observers\"]={},[\"release\"]={[\"side\"]=\"back\",},[\"signals\"]={},[\"station\"]=\"station1\",[\"status\"]=\"entwurf\",},},[\"version\"]=1,}",
      ["crn_data/format.lua"] = "-- crn d0550aa6 35\
{[\"format\"]=1,[\"program\"]=\"0.1.0\",}",
      ["crn_data/umgebung.lua"] = "-- crn a65d107d 48\
{[\"signature\"]=\"host=CC test;station=5ef053b4\",}",
    },
    ["hauptstelle"] = {
      ["crn_data/clock.lua"] = "-- crn 60690722 24\
{[\"boots\"]=1,[\"t\"]=120,}",
      ["crn_data/clock.lua.prev"] = "-- crn 59aa06f8 23\
{[\"boots\"]=1,[\"t\"]=90,}",
      ["crn_data/config.lua"] = "-- crn 7ba15fd3 276\
{[\"devices\"]={},[\"junction\"]={[\"conflicts\"]={},[\"connections\"]={},[\"moves\"]={},},[\"network\"]={[\"name\"]=\"Testnetz\",},[\"node\"]={[\"id\"]=\"hauptstelle\",[\"name\"]=\"hauptstelle\",[\"roles\"]={[1]=\"zentrale\",},},[\"revision\"]=1,[\"status\"]=\"aktiv\",[\"tests\"]={},[\"tracks\"]={},[\"version\"]=1,}",
      ["crn_data/epoche.lua"] = "-- crn 111602fd 10\
{[\"n\"]=1,}",
      ["crn_data/format.lua"] = "-- crn d0550aa6 35\
{[\"format\"]=1,[\"program\"]=\"0.1.0\",}",
      ["crn_data/nodesich/bahnhof.lua"] = "-- crn 9e3417b3 871\
{[\"config\"]=\"{[\\034devices\\034]={[\\034station1\\034]={[\\034device\\034]=\\034Create_Station_1\\034,[\\034kind\\034]=\\034station\\034,},},[\\034junction\\034]={[\\034conflicts\\034]={},[\\034connections\\034]={},[\\034moves\\034]={},},[\\034network\\034]={[\\034central_id\\034]=\\034hauptstelle\\034,[\\034name\\034]=\\034Testnetz\\034,},[\\034node\\034]={[\\034id\\034]=\\034bahnhof\\034,[\\034name\\034]=\\034bahnhof\\034,[\\034roles\\034]={[1]=\\034passagierbahnhof\\034,},},[\\034registration_station\\034]=\\034station1\\034,[\\034revision\\034]=1,[\\034status\\034]=\\034aktiv\\034,[\\034tests\\034]={},[\\034tracks\\034]={[\\034gleis1\\034]={[\\034direction\\034]=\\034beide\\034,[\\034name\\034]=\\034Gleis 1\\034,[\\034observers\\034]={},[\\034release\\034]={[\\034side\\034]=\\034back\\034,},[\\034signals\\034]={},[\\034station\\034]=\\034station1\\034,[\\034status\\034]=\\034entwurf\\034,},},[\\034version\\034]=1,}\",[\"revision\"]=1,[\"t\"]=1,}",
      ["crn_data/nodesich/strecke.lua"] = "-- crn e5d45a1a 1102\
{[\"config\"]=\"{[\\034devices\\034]={[\\034signal1\\034]={[\\034device\\034]=\\034Sig_1\\034,[\\034kind\\034]=\\034signal\\034,},[\\034signal2\\034]={[\\034device\\034]=\\034Sig_2\\034,[\\034kind\\034]=\\034signal\\034,},[\\034signal3\\034]={[\\034device\\034]=\\034Sig_3\\034,[\\034kind\\034]=\\034signal\\034,},},[\\034junction\\034]={[\\034conflicts\\034]={},[\\034connections\\034]={},[\\034moves\\034]={},},[\\034network\\034]={[\\034central_id\\034]=\\034hauptstelle\\034,[\\034name\\034]=\\034Testnetz\\034,},[\\034node\\034]={[\\034id\\034]=\\034strecke\\034,[\\034name\\034]=\\034strecke\\034,[\\034roles\\034]={[1]=\\034signal\\034,},},[\\034revision\\034]=1,[\\034status\\034]=\\034aktiv\\034,[\\034tests\\034]={},[\\034tracks\\034]={[\\034gleis1\\034]={[\\034direction\\034]=\\034beide\\034,[\\034name\\034]=\\034Gleis 1\\034,[\\034observers\\034]={},[\\034signals\\034]={[1]=\\034signal1\\034,[2]=\\034signal2\\034,},[\\034status\\034]=\\034entwurf\\034,},[\\034gleis2\\034]={[\\034direction\\034]=\\034beide\\034,[\\034name\\034]=\\034Gleis 2\\034,[\\034observers\\034]={},[\\034signals\\034]={[1]=\\034signal3\\034,},[\\034status\\034]=\\034entwurf\\034,},},[\\034version\\034]=1,}\",[\"revision\"]=1,[\"t\"]=1,}",
      ["crn_data/umgebung.lua"] = "-- crn b34d0ad5 31\
{[\"signature\"]=\"host=CC test\",}",
    },
    ["strecke"] = {
      ["crn_data/clock.lua"] = "-- crn 60690722 24\
{[\"boots\"]=1,[\"t\"]=120,}",
      ["crn_data/clock.lua.prev"] = "-- crn 59aa06f8 23\
{[\"boots\"]=1,[\"t\"]=90,}",
      ["crn_data/config.lua"] = "-- crn 5f1aed8f 709\
{[\"devices\"]={[\"signal1\"]={[\"device\"]=\"Sig_1\",[\"kind\"]=\"signal\",},[\"signal2\"]={[\"device\"]=\"Sig_2\",[\"kind\"]=\"signal\",},[\"signal3\"]={[\"device\"]=\"Sig_3\",[\"kind\"]=\"signal\",},},[\"junction\"]={[\"conflicts\"]={},[\"connections\"]={},[\"moves\"]={},},[\"network\"]={[\"central_id\"]=\"hauptstelle\",[\"name\"]=\"Testnetz\",},[\"node\"]={[\"id\"]=\"strecke\",[\"name\"]=\"strecke\",[\"roles\"]={[1]=\"signal\",},},[\"revision\"]=1,[\"status\"]=\"aktiv\",[\"tests\"]={},[\"tracks\"]={[\"gleis1\"]={[\"direction\"]=\"beide\",[\"name\"]=\"Gleis 1\",[\"observers\"]={},[\"signals\"]={[1]=\"signal1\",[2]=\"signal2\",},[\"status\"]=\"entwurf\",},[\"gleis2\"]={[\"direction\"]=\"beide\",[\"name\"]=\"Gleis 2\",[\"observers\"]={},[\"signals\"]={[1]=\"signal3\",},[\"status\"]=\"entwurf\",},},[\"version\"]=1,}",
      ["crn_data/format.lua"] = "-- crn d0550aa6 35\
{[\"format\"]=1,[\"program\"]=\"0.1.0\",}",
      ["crn_data/umgebung.lua"] = "-- crn 93890ffc 47\
{[\"signature\"]=\"host=CC test;signal=ad6f2149\",}",
    },
  },
  -- Vor dem Erstaufbau-Durchgang
  ["0f1bfbc"] = {
    ["bahnhof"] = {
      ["crn_data/clock.lua"] = "-- crn 60690722 24\
{[\"boots\"]=1,[\"t\"]=120,}",
      ["crn_data/clock.lua.prev"] = "-- crn 59aa06f8 23\
{[\"boots\"]=1,[\"t\"]=90,}",
      ["crn_data/config.lua"] = "-- crn 36f9c3a6 568\
{[\"devices\"]={[\"station1\"]={[\"device\"]=\"Create_Station_1\",[\"kind\"]=\"station\",},},[\"junction\"]={[\"conflicts\"]={},[\"connections\"]={},[\"moves\"]={},},[\"network\"]={[\"central_id\"]=\"hauptstelle\",[\"name\"]=\"Testnetz\",},[\"node\"]={[\"id\"]=\"bahnhof\",[\"name\"]=\"bahnhof\",[\"roles\"]={[1]=\"passagierbahnhof\",},},[\"registration_station\"]=\"station1\",[\"revision\"]=1,[\"status\"]=\"aktiv\",[\"tests\"]={},[\"tracks\"]={[\"gleis1\"]={[\"direction\"]=\"beide\",[\"name\"]=\"Gleis 1\",[\"observers\"]={},[\"release\"]={[\"side\"]=\"back\",},[\"signals\"]={},[\"station\"]=\"station1\",[\"status\"]=\"entwurf\",},},[\"version\"]=1,}",
      ["crn_data/format.lua"] = "-- crn d0550aa6 35\
{[\"format\"]=1,[\"program\"]=\"0.1.0\",}",
      ["crn_data/umgebung.lua"] = "-- crn a65d107d 48\
{[\"signature\"]=\"host=CC test;station=5ef053b4\",}",
    },
    ["hauptstelle"] = {
      ["crn_data/clock.lua"] = "-- crn 60690722 24\
{[\"boots\"]=1,[\"t\"]=120,}",
      ["crn_data/clock.lua.prev"] = "-- crn 59aa06f8 23\
{[\"boots\"]=1,[\"t\"]=90,}",
      ["crn_data/config.lua"] = "-- crn 7ba15fd3 276\
{[\"devices\"]={},[\"junction\"]={[\"conflicts\"]={},[\"connections\"]={},[\"moves\"]={},},[\"network\"]={[\"name\"]=\"Testnetz\",},[\"node\"]={[\"id\"]=\"hauptstelle\",[\"name\"]=\"hauptstelle\",[\"roles\"]={[1]=\"zentrale\",},},[\"revision\"]=1,[\"status\"]=\"aktiv\",[\"tests\"]={},[\"tracks\"]={},[\"version\"]=1,}",
      ["crn_data/epoche.lua"] = "-- crn 111602fd 10\
{[\"n\"]=1,}",
      ["crn_data/format.lua"] = "-- crn d0550aa6 35\
{[\"format\"]=1,[\"program\"]=\"0.1.0\",}",
      ["crn_data/netz.lua"] = "-- crn 1d47a58f 518\
{[\"areas\"]={[\"B0001\"]={[\"ends\"]={[1]=\"Westbahnhof\",[2]=\"Ostbahnhof\",},[\"name\"]=\"West-Ost\",[\"order\"]=2,[\"rev\"]=1,},},[\"counters\"]={[\"bereich\"]=1,[\"betriebsstelle\"]=0,[\"gleis\"]=2,[\"knoten\"]=0,[\"node\"]=0,[\"standort\"]=0,},[\"junctions\"]={},[\"nodes\"]={},[\"revision\"]=1,[\"sites\"]={},[\"stations\"]={},[\"tracks\"]={[\"A0001\"]={[\"area\"]=\"B0001\",[\"direction\"]=\"Ostbahnhof\",[\"name\"]=\"Gleis 1\",[\"order\"]=1,[\"rev\"]=1,},[\"A0002\"]={[\"area\"]=\"B0001\",[\"direction\"]=\"Westbahnhof\",[\"name\"]=\"Gleis 2\",[\"order\"]=2,[\"rev\"]=1,},},[\"version\"]=2,}",
      ["crn_data/nodesich/bahnhof.lua"] = "-- crn 9e3417b3 871\
{[\"config\"]=\"{[\\034devices\\034]={[\\034station1\\034]={[\\034device\\034]=\\034Create_Station_1\\034,[\\034kind\\034]=\\034station\\034,},},[\\034junction\\034]={[\\034conflicts\\034]={},[\\034connections\\034]={},[\\034moves\\034]={},},[\\034network\\034]={[\\034central_id\\034]=\\034hauptstelle\\034,[\\034name\\034]=\\034Testnetz\\034,},[\\034node\\034]={[\\034id\\034]=\\034bahnhof\\034,[\\034name\\034]=\\034bahnhof\\034,[\\034roles\\034]={[1]=\\034passagierbahnhof\\034,},},[\\034registration_station\\034]=\\034station1\\034,[\\034revision\\034]=1,[\\034status\\034]=\\034aktiv\\034,[\\034tests\\034]={},[\\034tracks\\034]={[\\034gleis1\\034]={[\\034direction\\034]=\\034beide\\034,[\\034name\\034]=\\034Gleis 1\\034,[\\034observers\\034]={},[\\034release\\034]={[\\034side\\034]=\\034back\\034,},[\\034signals\\034]={},[\\034station\\034]=\\034station1\\034,[\\034status\\034]=\\034entwurf\\034,},},[\\034version\\034]=1,}\",[\"revision\"]=1,[\"t\"]=1,}",
      ["crn_data/nodesich/strecke.lua"] = "-- crn e5d45a1a 1102\
{[\"config\"]=\"{[\\034devices\\034]={[\\034signal1\\034]={[\\034device\\034]=\\034Sig_1\\034,[\\034kind\\034]=\\034signal\\034,},[\\034signal2\\034]={[\\034device\\034]=\\034Sig_2\\034,[\\034kind\\034]=\\034signal\\034,},[\\034signal3\\034]={[\\034device\\034]=\\034Sig_3\\034,[\\034kind\\034]=\\034signal\\034,},},[\\034junction\\034]={[\\034conflicts\\034]={},[\\034connections\\034]={},[\\034moves\\034]={},},[\\034network\\034]={[\\034central_id\\034]=\\034hauptstelle\\034,[\\034name\\034]=\\034Testnetz\\034,},[\\034node\\034]={[\\034id\\034]=\\034strecke\\034,[\\034name\\034]=\\034strecke\\034,[\\034roles\\034]={[1]=\\034signal\\034,},},[\\034revision\\034]=1,[\\034status\\034]=\\034aktiv\\034,[\\034tests\\034]={},[\\034tracks\\034]={[\\034gleis1\\034]={[\\034direction\\034]=\\034beide\\034,[\\034name\\034]=\\034Gleis 1\\034,[\\034observers\\034]={},[\\034signals\\034]={[1]=\\034signal1\\034,[2]=\\034signal2\\034,},[\\034status\\034]=\\034entwurf\\034,},[\\034gleis2\\034]={[\\034direction\\034]=\\034beide\\034,[\\034name\\034]=\\034Gleis 2\\034,[\\034observers\\034]={},[\\034signals\\034]={[1]=\\034signal3\\034,},[\\034status\\034]=\\034entwurf\\034,},},[\\034version\\034]=1,}\",[\"revision\"]=1,[\"t\"]=1,}",
      ["crn_data/umgebung.lua"] = "-- crn b34d0ad5 31\
{[\"signature\"]=\"host=CC test\",}",
    },
    ["strecke"] = {
      ["crn_data/clock.lua"] = "-- crn 60690722 24\
{[\"boots\"]=1,[\"t\"]=120,}",
      ["crn_data/clock.lua.prev"] = "-- crn 59aa06f8 23\
{[\"boots\"]=1,[\"t\"]=90,}",
      ["crn_data/config.lua"] = "-- crn 5f1aed8f 709\
{[\"devices\"]={[\"signal1\"]={[\"device\"]=\"Sig_1\",[\"kind\"]=\"signal\",},[\"signal2\"]={[\"device\"]=\"Sig_2\",[\"kind\"]=\"signal\",},[\"signal3\"]={[\"device\"]=\"Sig_3\",[\"kind\"]=\"signal\",},},[\"junction\"]={[\"conflicts\"]={},[\"connections\"]={},[\"moves\"]={},},[\"network\"]={[\"central_id\"]=\"hauptstelle\",[\"name\"]=\"Testnetz\",},[\"node\"]={[\"id\"]=\"strecke\",[\"name\"]=\"strecke\",[\"roles\"]={[1]=\"signal\",},},[\"revision\"]=1,[\"status\"]=\"aktiv\",[\"tests\"]={},[\"tracks\"]={[\"gleis1\"]={[\"direction\"]=\"beide\",[\"name\"]=\"Gleis 1\",[\"observers\"]={},[\"signals\"]={[1]=\"signal1\",[2]=\"signal2\",},[\"status\"]=\"entwurf\",},[\"gleis2\"]={[\"direction\"]=\"beide\",[\"name\"]=\"Gleis 2\",[\"observers\"]={},[\"signals\"]={[1]=\"signal3\",},[\"status\"]=\"entwurf\",},},[\"version\"]=1,}",
      ["crn_data/format.lua"] = "-- crn d0550aa6 35\
{[\"format\"]=1,[\"program\"]=\"0.1.0\",}",
      ["crn_data/umgebung.lua"] = "-- crn 93890ffc 47\
{[\"signature\"]=\"host=CC test;signal=ad6f2149\",}",
    },
  },
}
