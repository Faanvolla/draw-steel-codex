---@meta

--- Captures a snapshot of the current combat state, including initiative, characters, documents, and objects, for later restoration.
--- @class CombatCheckpoint
CombatCheckpoint = {}

--- Restores the game state to the snapshot captured when this checkpoint was created. Returns nil on success, or a message saying why nothing was restored.
--- @return string|nil
function CombatCheckpoint:Restore() end
