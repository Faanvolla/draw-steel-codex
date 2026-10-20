---@meta

--- A 3D tracker token for the tabletop (dice.CreateTableTracker): a metal medallion with a number on its face, rendered into an image Lua shows as a panel's bgimage (image), so windows cover it like any UI. It takes no mouse input; Lua says when it is held.
--- @class TableTrackerLua
--- @field valid boolean (Read-only) false once the token has been destroyed.
--- @field text string The number on its face.
--- @field held boolean True while it is being dragged: it lifts and grows a little, as a picked-up die does.
--- @field size number Its diameter in screen pixels.
--- @field tilt number How far it leans back, in degrees (0-60), so its near edge shows.
--- @field image string (Read-only) The bgimage that shows the token: a square centred on it, imageSize pixels across, with room for its shadow.
--- @field imageSize number (Read-only) How wide image is, in screen pixels, when the token is size pixels across.
TableTrackerLua = {}

--- Shows or hides the token (hidden, it is not rendered).
--- @param visible boolean
--- @return nil
function TableTrackerLua:SetVisible(visible) end

--- Removes the token.
--- @return nil
function TableTrackerLua:Destroy() end
