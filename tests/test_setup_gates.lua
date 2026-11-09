-- Purpose: Rollenabhaengige Pflichtpruefungen auch ohne UI und nach Geraeteausfall.
local t = dofile('tests/lib/t.lua')
local create = dofile('tests/fakes/create.lua')
local detect = require('dev.detect')
local model = require('setup.model')
local wizard = require('setup.wizard')
local function fixture(role)
  local world = create.world()
  world.add_modem('left', true)
  world.add_observer('obs')
  world.add_station('station')
  local w = wizard.new({scan=function() return detect.scan(world.peripheral) end,
    env={peripheral=world.peripheral, redstone=world.redstone}, now=function() return 1 end})
  w.set_mode('join'); w.set_network('Netz','z'); w.set_name('Nord'); w.toggle_role(role)
  return w, world
end
return {
  {'Geraeteausfall vor Aktivierung wird frisch erkannt', function()
    local w,world=fixture('depot'); w.toggle_device('station')
    local id=w.add_track('Gleis 1'); w.toggle_track_station(id,next(w.config.devices))
    for _,test in ipairs(w.tests()) do t.eq(w.run_test(test.id),true) end
    t.eq(w.all_tests_ok(),true)
    world.devices.station=nil
    t.eq(w.finish({save=function() return true end},'/x'),nil,'ohne frische Pruefung wird nicht aktiviert')
    world.add_station('station'); w.rescan()
    t.eq(w.all_tests_ok(),false,'Ausfall entwertet den alten Test')
  end},
  {'Rollenwechsel entfernt unpassende Auswahl', function()
    local w=fixture('depot');w.toggle_device('station');w.add_track('Abstellplatz')
    w.toggle_role('anmeldung')
    local ok,why,effect=w.toggle_role('depot')
    t.eq(ok,false); t.eq(why,'bestaetigen'); t.eq(effect.tracks,1,'das Abwaehlen nennt, was es entfernt')
    t.eq(#w.tracks(),1,'ohne Bestaetigung bleibt alles stehen')
    t.eq(w.toggle_role('depot',true),true)
    t.eq(#w.tracks(),0,'die Gleise gehoeren zur Bahnhofsrolle')
    t.eq(w.device_selected('station'),true,'die Station bleibt fuer die Anmeldung')
    t.eq(w.allowed_devices().observer,nil)
  end},
  {'Laufende Node: Es gibt keinen Entwurf-Knopf; Abbrechen verwirft die Kopie, die laufende Einrichtung bleibt', function()
    local driver=dofile('tests/lib/ui_driver.lua')
    local create=dofile('tests/fakes/create.lua')
    local storelib=require('core.store')
    for _,size in ipairs({{51,19},{100,40}}) do
      local world=create.world();world.add_modem('left',true);world.add_station('Create_Station_1')
      local d=driver.new({world=world,width=size[1],height=size[2]})
      local model=require('setup.model')
      local config=model.new('hof',{'bahnhof'},{name='Testnetz',central_id='zentrale'})
      config.node.id='hof'
      local tid=model.add_track(config,'Gleis 1')
      local did=model.add_device(config,'station','Create_Station_1')
      model.assign(config,tid,'station',did)
      config.status='aktiv'
      d.fs.makeDir('/crn_data')
      local store=storelib.new(d.fs)
      store.save('/crn_data/config.lua',config)
      d.restart()
      local v=d.view();v.set_page('einrichtung')
      d.tap(v,'act:start')
      d.node.render()
      -- einen Entwurf gibt es nicht mehr: weder Knopf noch Handler
      local page=v.current_page()
      for _,a in ipairs(page.actions(v)) do t.ok(a.id~='entwurf','kein Entwurf-Knopf') end
      v.dispatch('act:entwurf')
      d.node.render()
      t.eq(store.load('/crn_data/config.lua').status,'aktiv')
      t.eq(d.node.status().text,'Bereit')
      d.tap(v,'act:abbrechen');d.tap(v,'act:abbrechen')
      t.contains(v.hint,'laufende Einrichtung bleibt')
      t.eq(store.load('/crn_data/config.lua').status,'aktiv','Abbrechen laesst die laufende Node unberuehrt')
      t.eq(d.node.status().text,'Bereit')
    end
  end},
  {'Zeichnen liest die Geraete nicht neu und veraendert keine Pruefergebnisse', function()
    local driver=dofile('tests/lib/ui_driver.lua')
    local create=dofile('tests/fakes/create.lua')
    local world=create.world();world.add_modem('left',true);world.add_station('Create_Station_1');world.add_signal('Create_Signal_5')
    local names=0
    local real=world.peripheral.getNames
    world.peripheral.getNames=function(...) names=names+1 return real(...) end
    local d=driver.new({world=world});d.restart()
    local v=d.view();v.set_page('einrichtung')
    d.tap(v,'act:start')
    d.tap(v,'sel:modus:2');d.tap(v,'act:weiter')
    d.tap(v,'sel:netzwahl:1');d.tap(v,'act:weiter')
    d.type(v,'netz','Testnetz');d.tap(v,'act:weiter')
    d.type(v,'zentrale','zentrale');d.tap(v,'act:weiter')
    d.tap(v,'sel:rollen:3');d.tap(v,'act:weiter')
    d.tap(v,'act:von_hand')
    d.type(v,'name','Hof');d.tap(v,'act:weiter')
    d.tap_row(v,'geraete','Create_Station_1')
    local before=names
    for _=1,10 do d.node.render() end
    t.eq(names,before,'zehnmal zeichnen liest keine Geraete')
    d.tap(v,'act:neu_scannen')
    t.ok(names>before,'ausdrueckliches Neu lesen liest weiterhin')
  end},
  {'Neue Node: ohne Entwurf; Abbrechen speichert nichts, danach beginnt die Einrichtung von vorn', function()
    local driver=dofile('tests/lib/ui_driver.lua')
    local create=dofile('tests/fakes/create.lua')
    local world=create.world();world.add_modem('left',true)
    local d=driver.new({world=world});d.restart()
    local v=d.view();v.set_page('einrichtung')
    d.tap(v,'act:start')
    v.dispatch('act:entwurf')                 -- gibt es nicht mehr
    t.ok(not d.fs.exists('/crn_data/config.lua'),'nichts gespeichert')
    d.tap(v,'act:abbrechen');d.tap(v,'act:abbrechen')
    t.ok(not d.fs.exists('/crn_data/config.lua'))
    t.eq(d.node.config,nil)
    d.tap(v,'act:start')
    t.eq(d.node.setup.session().screen,'1.modus','von vorn')
  end},
  {'UI sperrt Weiter auch bei direktem Aufruf und zeigt nur passende Geraete', function()
    local driver=dofile('tests/lib/ui_driver.lua')
    local create=dofile('tests/fakes/create.lua')
    for _,size in ipairs({{51,19},{100,40}}) do
      local world=create.world();world.add_modem('left',true);world.add_signal('sig');world.add_station('Depotstation')
      local d=driver.new({world=world,width=size[1],height=size[2]});d.restart()
      local v=d.view();v.set_page('einrichtung');v.dispatch('act:start')
      local session=d.node.setup.session();local w=session.wiz
      w.set_mode('join');w.set_network('N','z');w.set_name('Depot Nord');w.toggle_role('depot')
      session.manual=true      -- der manuelle Weg ("Von Hand") neben der gefuehrten Einrichtung
      session.screen='3.geraete';w.step=3;d.node.render()
      t.ok(d.has(v,'Depotstation'))
      t.ok(not d.has(v,'sig'), 'Create-Signale gehoeren nicht mehr zur Auswahl (Create regelt die Strecke)')
      t.eq(d.area(v,'act:weiter').enabled,false)
      v.dispatch('act:weiter');t.eq(session.screen,'3.geraete')
      w.toggle_device('Depotstation');d.node.render();v.dispatch('act:weiter')
      t.eq(session.screen,'4.gleise')
      for _,a in ipairs(v.touch.areas) do t.ok(a.y+a.h-1<=size[2] and a.x+a.w-1<=size[1]) end
    end
  end},
  {'Depotrolle blendet Signale aus (Create regelt die Strecke)', function()
    local w = fixture('depot')
    t.eq(w.allowed_devices().signal, nil)
    t.eq(w.toggle_device('sig'), false)
    t.eq(w.allowed_devices().station, true)
  end},
  {'Pflichtgeraet und Gleis blockieren Weiter', function()
    local w = fixture('depot')
    w.step=3; t.eq(w.next(),false); t.eq(w.step,3)
    w.toggle_device('station'); t.eq(w.next(),true)
    t.eq(w.next(),false); t.eq(w.step,4)
    local id=w.add_track('Gleis 1'); local sid=next(w.config.devices)
    w.toggle_track_station(id,sid)
    t.eq(w.next(),true); t.eq(w.next(),false); t.eq(w.step,5)
  end},
  {'Aenderung der Zuordnung entwertet bestandene Tests', function()
    local w = fixture('depot'); w.toggle_device('station')
    local id=w.add_track('Gleis 1'); w.toggle_track_station(id,next(w.config.devices))
    for _,test in ipairs(w.tests()) do t.eq(w.run_test(test.id),true) end
    t.eq(w.all_tests_ok(),true)
    w.config.tracks[id].length=99; t.eq(w.all_tests_ok(),false)
  end},
  {'Leeres Depot darf nie aktiviert werden', function()
    local w = fixture('depot'); local saved
    local status=w.finish({save=function(_,c) saved=c; return true end},'/x')
    t.eq(status,nil); t.eq(saved,nil,'nichts gespeichert')
  end},
  {'Bearbeiten veraendert die aktive Konfiguration nicht', function()
    local c=model.new('Alt',{'depot'},{name='N',central_id='z'})
    local w=wizard.new({existing=c,scan=function() return {} end,env={},now=function() return 0 end})
    w.set_name('Neu'); t.eq(c.node.name,'Alt')
  end},
}
