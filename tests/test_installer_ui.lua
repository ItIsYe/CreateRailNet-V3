-- Purpose: Der eigenstaendige Installer-Renderer funktioniert vor Installation auf kleinen und grossen Terminals.
local t=dofile('tests/lib/t.lua')
local screen=dofile('tests/fakes/screen.lua')
_G.__CRN_TEST=true
local installer=dofile('installer.lua')
local unpacker=table.unpack or unpack
return {
  {'Installer Auswahl und Text bleiben bei kleinen Flaechen erreichbar',function()
    for _,size in ipairs({{51,19},{100,40}}) do
      local target=screen.new(size[1],size[2])
      local events={{'key',267},{'key',264},{'key',257}}
      local env=installer.dialog_env({read=function() return 'v1' end},target,function() return unpacker(table.remove(events,1)) end)
      for i=1,30 do env.print('Pruefung '..i) end
      local result=env.choose({{key='j',text='Installieren'},{key='q',text='Abbrechen'}})
      t.eq(result,'q'); t.ok(env.ui_state.offset>0)
      for _,a in ipairs(env.ui_state.areas) do
        t.ok(a.x>=1 and a.y>=1 and a.x+a.w-1<=size[1] and a.y+a.h-1<=size[2])
      end
      env.progress(5,10)
      t.contains(target.text(),'Dateien geprueft: 5 / 10')
    end
  end},
  {'Installer alle sieben Rollen per Tastatur erreichbar',function()
    local target=screen.new(51,19)
    local events={}; for i=1,6 do events[#events+1]={'key',264} end; events[#events+1]={'key',257}
    local unpacker=table.unpack or unpack
    local env=installer.dialog_env({read=function() end},target,function() return unpacker(table.remove(events,1)) end)
    local entries={};for i=1,7 do entries[i]={key=tostring(i),text='Rolle '..i} end
    t.eq(env.choose(entries),'7')
    t.contains(target.text(),'Rolle 7')
  end},
  {'Installer-Dialog gibt Farben und Bildschirm zurueck und laesst den Verlauf als Text stehen',function()
    for _,size in ipairs({{51,19},{100,40}}) do
      local target=screen.new(size[1],size[2])
      target.setPaletteColour(32768,0.2,0.4,0.6)       -- Farbe des Spielers vor dem Installer
      local before={target.getPaletteColour(32768)}
      local printed={}
      local env=installer.dialog_env({print=function(text) printed[#printed+1]=text end,read=function() return '' end},target,function() return 'key',257 end)
      t.ok(target.palette[32768][1]~=before[1],'Dialog setzt eigene Farben')
      env.print('CRN Installer   Schritt 1 von 3')
      env.print('Installiert: Version 0.1.0')
      env.restore()
      local after={target.getPaletteColour(32768)}
      t.eq(after[1],before[1]); t.eq(after[2],before[2]); t.eq(after[3],before[3])
      t.eq(table.concat(printed,'|'),'Installiert: Version 0.1.0','Verlauf ohne Kopfzeile bleibt stehen')
      env.restore()
      t.eq(#printed,1,'zweites Aufraeumen tut nichts')
    end
  end},
  {'Installer-Dialog kompakt: Auswahl braucht eine Zeile je Eintrag, die Zusammenfassung bleibt lesbar',function()
    local target=screen.new(51,19)
    local env=installer.dialog_env({read=function() return '' end},target,function() return 'key',257 end)
    for i=1,9 do env.print('Zeile '..i) end
    env.choose({{key='j',text='Installieren'},{key='z',text='Zurueck'},{key='q',text='Abbrechen'}})
    local text=target.text()
    for i=1,9 do t.contains(text,'Zeile '..i) end
    for _,a in ipairs(env.ui_state.areas) do t.eq(a.h,1) end
  end},
}
