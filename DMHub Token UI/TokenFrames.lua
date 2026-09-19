local mod = dmhub.GetModLoading()

--- Premium token frames: frame rings rendered with a real material (normal map,
--- roughness/metallic, sheen) instead of a flat texture. Definitions live here and
--- are registered with the engine through dmhub.tokenFrames; a token opts in by
--- pointing its appearance at one (see TokenFrames.Apply). Everything that only
--- knows the flat frame (GUI panels, shadows, other clients) keeps drawing the
--- albedo, so a premium frame degrades gracefully.
---
--- Proof of concept: one frame, "black-metal". Its maps are image assets in the
--- game this was authored in; a shipped frame would use core assets instead.
TokenFrames = {}

--- @class TokenFrameDefinition
--- @field id string
--- @field name string
--- @field albedo string AvatarFrame image asset guid. Transparent interior so the engine's centre flood-fill mask works.
--- @field normal nil|string Tangent-space normal map (raw RGB, +y up), loaded linear.
--- @field roughness nil|string R = roughness, G = metallic, loaded linear.
--- @field matcap nil|string Optional sphere-lit environment image.
--- @field flipNormalY nil|boolean
--- @field params nil|table Shading parameters; see dmhub.tokenFrames:Register.

--- @type table<string, TokenFrameDefinition>
TokenFrames.definitions = {
    ["black-metal"] = {
        id = "black-metal",
        name = "Black Metal",
        albedo = "890a43aa-53d9-49a0-99e8-adfc94a173df",
        normal = "1e1d4711-e989-488b-91fc-d814174730a4",
        roughness = "a66dc8a7-5994-439c-9d6d-27eb13aa37ba",
        params = {
            normalStrength = 1.0,
            specStrength = 1.4,
            fresnelPower = 3.0,
            cameraReactivity = 1.0,
            eyeHeight = 1.4,
            ambient = 0.3,
            lightFollowsTimeOfDay = 0.6,
            lightDir = { x = -0.35, y = 0.55, z = 0.75 },
            sheenColor = "#d8dde6",
        },
    },
    ["chrome-blue"] = {
        id = "chrome-blue",
        name = "Blue Chrome",
        albedo = "6a1f0c2e-3b7d-4c9a-9e51-7f2d8a4b1c01",
        normal = "6a1f0c2e-3b7d-4c9a-9e51-7f2d8a4b1c02",
        roughness = "6a1f0c2e-3b7d-4c9a-9e51-7f2d8a4b1c03",
        matcap = "6a1f0c2e-3b7d-4c9a-9e51-7f2d8a4b1c04",
        params = {
            normalStrength = 1.0,
            specStrength = 1.5,
            fresnelPower = 3.0,
            cameraReactivity = 1.0,
            eyeHeight = 1.4,
            ambient = 0.35,
            matcapStrength = 1.0,
            sheenFromAlbedo = 1.0,
            albedoSheenBoost = 1.6,
            --HDR: the hottest matcap regions and the specular peak go above 1.0 and bloom.
            hdrGlow = 1.8,
            glowThreshold = 0.8,
            specGlow = 0.6,
            lightFollowsTimeOfDay = 0.5,
            lightDir = { x = -0.3, y = 0.6, z = 0.75 },
            sheenColor = "#ffffff",
        },
    },
}

for _, def in pairs(TokenFrames.definitions) do
    dmhub.tokenFrames:Register(def)
end

--- Ids of every registered frame, sorted by display name.
--- @return string[]
function TokenFrames.Ids()
    local ids = {}
    for id, _ in pairs(TokenFrames.definitions) do
        ids[#ids + 1] = id
    end
    table.sort(ids, function(a, b)
        return TokenFrames.definitions[a].name < TokenFrames.definitions[b].name
    end)
    return ids
end

--- Put a premium frame on a token and upload the appearance. Pass nil for id to go
--- back to a plain frame (the albedo stays as the frame texture; pass restoreFrame
--- to put a different frame asset back at the same time).
--- @param token CharacterToken
--- @param id nil|string
--- @param restoreFrame nil|string
function TokenFrames.Apply(token, id, restoreFrame)
    if token == nil or not token.valid then
        return
    end

    if id == nil or id == "" then
        token.portraitFrameMaterial = ""
        if restoreFrame ~= nil then
            token.portraitFrame = restoreFrame
        end
        token:UploadAppearance()
        return
    end

    local def = TokenFrames.definitions[id]
    if def == nil then
        dmhub.Error("TokenFrames.Apply: no frame registered with id " .. tostring(id))
        return
    end

    token.portraitFrame = def.albedo
    token.portraitFrameMaterial = def.id
    --The hue/saturation/brightness sliders tint the albedo before it is lit, so a tint
    --left over from a plain frame recolours the whole material (blue chrome turned green,
    --the orange rim purple). A premium frame is authored in its own colours: reset them.
    token.portraitFrameHueShift = 0
    token.portraitFrameSaturation = 1
    token.portraitFrameBrightness = 1
    token:UploadAppearance()
end

--- Apply a frame to every selected token. Convenience for testing from the console:
---   TokenFrames.ApplyToSelection("black-metal")
---   TokenFrames.ApplyToSelection(nil, "<plain frame guid>")
--- @param id nil|string
--- @param restoreFrame nil|string
function TokenFrames.ApplyToSelection(id, restoreFrame)
    for _, token in ipairs(dmhub.selectedTokens or {}) do
        TokenFrames.Apply(token, id, restoreFrame)
    end
end
