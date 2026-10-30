-- Purpose: Rollenabhaengige Pflichtpruefungen auch ohne UI und nach Geraeteausfall.
local t = dofile('tests/lib/t.lua')
local create = dofile('tests/fakes/create.lua')
local detect = require('dev.detect')
local model = require('setup.model')
local wizard = require('setup.wizard')
local function fixture(role)
  local world = create.world()
  world.add_modem('left', true)
  world.add_signal('sig')
  world.add_station('station')
  local w = wizard.new({scan=function() return detect.scan(world.peripheral) end,
    env={peripheral=world.peripheral, redstone=world.redstone}, now=function() return 1 end})
  w.set_mode('join'); w.set_network('Netz','z'); w.set_name('Nord'); w.toggle_role(role)
  return w, world
end
return {
  {'Geraeteausfall vor Aktivierung wird frisch erkannt', function()
    local w,world=fixture('signal'); w.toggle_device('sig')
    local id=w.add_track('Gleis 1'); w.toggle_track_device(id,'signals',next(w.config.devices))
    for _,test in ipairs(w.tests()) do t.eq(w.run_test(test.id,true),true) end
    t.eq(w.all_tests_ok(),true)
    world.devices.sig=nil
    t.eq(w.finish({save=function() return true end},'/x'),'entwurf')
    world.add_signal('sig'); w.rescan()
    t.eq(w.all_tests_ok(),false,'Ausfall entwertet den alten Test')
  end},
  {'Rollenwechsel entfernt unpassende Auswahl', function()
    local w=fixture('depot');w.toggle_device('station');w.add_track('Abstellplatz')
    w.toggle_role('signal');w.toggle_role('depot')
    t.eq(w.device_selected('station'),false)
    t.eq(w.allowed_devices().station,nil)
  end},
  {'UI sperrt Weiter auch bei direktem Aufruf und zeigt nur passende Geraete', function()
    local driver=dofile('tests/lib/ui_driver.lua')
    local create=dofile('tests/fakes/create.lua')
    for _,size in ipairs({{51,19},{100,40}}) do
      local world=create.world();world.add_modem('left',true);world.add_signal('sig');world.add_station('Depotstation')
      local d=driver.new({world=world,width=size[1],height=size[2]});d.restart()
      local v=d.view();v.set_page('einrichtung');v.dispatch('act:start')
      local session=d.node.setup.session();local w=session.wiz
      w.set_mode('join');w.set_network('N','z');w.set_name('Signal Nord');w.toggle_role('signal')
      session.screen='3.geraete';w.step=3;d.node.render()
      t.ok(not d.has(v,'Depotstation'))
      t.eq(d.area(v,'act:weiter').enabled,false)
      v.dispatch('act:weiter');t.eq(session.screen,'3.geraete')
      w.toggle_device('sig');d.node.render();v.dispatch('act:weiter')
      t.eq(session.screen,'4.gleise')
      for _,a in ipairs(v.touch.areas) do t.ok(a.y+a.h-1<=size[2] and a.x+a.w-1<=size[1]) end
    end
  end},
  {'Signalrolle blendet Bahnhof und Depotgeraete aus', function()
    local w = fixture('signal')
    t.eq(w.allowed_devices().station, nil)
    t.eq(w.toggle_device('station'), false)
    t.eq(w.allowed_devices().signal, true)
  end},
  {'Pflichtgeraet und Gleis blockieren Weiter', function()
    local w = fixture('signal')
    w.step=3; t.eq(w.next(),false); t.eq(w.step,3)
    w.toggle_device('sig'); t.eq(w.next(),true)
    t.eq(w.next(),false); t.eq(w.step,4)
    local id=w.add_track('Gleis 1'); local sid=next(w.config.devices)
    w.toggle_track_device(id,'signals',sid)
    t.eq(w.next(),true); t.eq(w.next(),false); t.eq(w.step,5)
  end},
  {'Aenderung der Zuordnung entwertet bestandene Tests', function()
    local w = fixture('signal'); w.toggle_device('sig')
    local id=w.add_track('Gleis 1'); w.toggle_track_device(id,'signals',next(w.config.devices))
    for _,test in ipairs(w.tests()) do t.eq(w.run_test(test.id,true),true) end
    t.eq(w.all_tests_ok(),true)
    w.set_direction(id,'hin'); t.eq(w.all_tests_ok(),false)
  end},
  {'Leere Signalnode darf nie aktiviert werden', function()
    local w = fixture('signal'); local saved
    local status=w.finish({save=function(_,c) saved=c; return true end},'/x')
    t.eq(status,'entwurf'); t.eq(saved.status,'entwurf')
  end},
  {'Bearbeiten veraendert die aktive Konfiguration nicht', function()
    local c=model.new('Alt',{'signal'},{name='N',central_id='z'})
    local w=wizard.new({existing=c,scan=function() return {} end,env={},now=function() return 0 end})
    w.set_name('Neu'); t.eq(c.node.name,'Alt')
  end},
}
