---@meta

--- Registry of premium token frame materials. Register{...} defines a frame; a token uses it by setting token.portraitFrameMaterial to the id and token.portraitFrame to the entry's albedo asset. `frames` is iterable from Lua (`for id, entry in pairs(dmhub.tokenFrames.frames) do ... end`).
--- @class TokenFramesLuaInterface
--- @field frames any Map of registered frame id -> entry table (the table passed to Register). Iterable from Lua.
TokenFramesLuaInterface = {}

--- Register a premium frame material. `albedo` is the frame image asset (an AvatarFrame image with a transparent interior; the token's portraitFrame must be set to it too). `normal` is a tangent-space normal map stored as raw RGB (loaded linear), `roughness` packs roughness in R and metallic in G, `matcap` is an optional sphere-lit environment image. All are cloud image asset guids. `params` tunes the shading: normalStrength, specStrength, fresnelPower, cameraReactivity (how much the view angle changes across the viewport), eyeHeight (virtual eye height in viewport half-heights), roughness / metallic (used when no roughness map), matcapStrength, ambient, lightFollowsTimeOfDay (0..1 blend toward the map's sun), lightDir {x,y,z} (fallback/fixed light, +z toward the camera), sheenColor and lightColor ("#rrggbb" or {r,g,b}), sheenFromAlbedo (0..1: metal reflections take the frame's own colour instead of sheenColor; use 1 for coloured chrome) and albedoSheenBoost (brightens the albedo-derived reflection colour, default 1.6). HDR: the map is bloomed above 1.0, so hdrGlow (extra brightness of matcap texels above glowThreshold, default 0 / 0.7) and specGlow (extra specular peak, default 0) make just the highlights bloom.
--- @param entry table { id: string, name: string|nil, albedo: string, normal: string|nil, roughness: string|nil, matcap: string|nil, flipNormalY: boolean|nil, params: table|nil }
function TokenFramesLuaInterface:Register(entry) end

--- Returns the registered entry table for a frame id, or nil if no such frame is registered.
--- @param id string
--- @return table|nil
function TokenFramesLuaInterface:Get(id) end

--- Diagnostic: describes the frame material state on a token's renderer -- keyword, which maps resolved to textures (with their sizes and formats), and the parameter vectors currently on the material. Returns a table, or nil if the token has no renderer.
--- @param token CharacterToken
--- @return table|nil
function TokenFramesLuaInterface:Inspect(token) end
