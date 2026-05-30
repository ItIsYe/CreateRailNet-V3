--[[
Purpose: Offline setup wizard tests.
Public API: returns table of tests.
]]

local setup_wizard = require("src.tools.setup_wizard")

local function fake_report()
  return {
    generated_at = 1,
    peripherals = {
      { name = "Create_Station_0", type = "Create_Station", methods = { "setSchedule", "isTrainPresent", "getStationName" } },
      { name = "Create_TrainObserver_0", type = "Create_TrainObserver", methods = { "isTrainPassing", "getPassingTrainName" } },
      { name = "Create_Signal_0", type = "Create_Signal", methods = { "setForcedRed", "getState" } },
      { name = "monitor_0", type = "monitor", methods = { "clear", "write" } }
    }
  }
end

return {
  test_classifies_create_station = function()
    local role = setup_wizard.classify_peripheral({ name = "Create_Station_0", type = "Create_Station", methods = { "setSchedule" } })
    assert(role == "create_station")
  end,

  test_classifies_train_observer = function()
    local role = setup_wizard.classify_peripheral({ name = "Create_TrainObserver_0", type = "Create_TrainObserver", methods = { "isTrainPassing" } })
    assert(role == "train_observer")
  end,

  test_build_config_from_fake_report = function()
    local cfg, meta = setup_wizard.build_config(fake_report(), { from_station = "Alpha", to_station = "Beta", kind = "passenger" })
    assert(meta.valid)
    assert(cfg.nodes[2].create_station == "Create_Station_0")
    assert(cfg.nodes[4].id == "Alpha")
    assert(cfg.routes[1].to == "Beta")
  end,

  test_build_config_warns_without_peripherals = function()
    local cfg, meta = setup_wizard.build_config({ peripherals = {} }, {})
    assert(meta.valid)
    assert(#meta.warnings > 0)
    assert(cfg.nodes[2].schedule_station == "Create_Station_0")
  end
}
