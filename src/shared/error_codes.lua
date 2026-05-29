--[[
Purpose: Shared error codes for safer diagnostics and operator messages.
Public API: codes table and make(code, message, details).
]]

local error_codes = {}

error_codes.codes = {
  ROUTE_NOT_FOUND = "ROUTE_NOT_FOUND",
  ROUTE_BLOCKED = "ROUTE_BLOCKED",
  SWITCH_LOCKED = "SWITCH_LOCKED",
  SENSOR_UNKNOWN = "SENSOR_UNKNOWN",
  SENSOR_UNEXPECTED = "SENSOR_UNEXPECTED",
  NODE_TIMEOUT = "NODE_TIMEOUT",
  MANUAL_REJECTED = "MANUAL_REJECTED",
  MAINTENANCE_LOCKED = "MAINTENANCE_LOCKED",
  CONFIG_INVALID = "CONFIG_INVALID",
  HARDWARE_UNAVAILABLE = "HARDWARE_UNAVAILABLE"
}

function error_codes.make(code, message, details)
  return {
    code = code or "UNKNOWN",
    message = message or code or "unknown error",
    details = details or {}
  }
end

return error_codes
