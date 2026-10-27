--[[
Purpose: Groessenbudget je Rolle (Ergaenzung E6). Ein CC:Tweaked Computer fasst fest 1 000 000 Byte (Messwert M01), jede Datei zaehlt mindestens 500 Byte.
]]

return {
  capacity = 1000000,
  min_file = 500,
  program_max = 500000,
  data_max = 300000,
  free_min = 200000,
}
