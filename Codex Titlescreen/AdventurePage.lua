local mod = dmhub.GetModLoading()

--The store page for an adventure (a Module shop item with an adventure page
--config). Replaces the generic details layout for those items with the
--storefront pattern: a full-bleed hero, one media viewer with a filmstrip,
--then a two-column body (about + cast on the left, the buy box on the right).
--See ADVENTURE_SHOP_BRIEF.md.
--
--Page config shape:
--  {
--      heroImage = "<image guid>",   --key art; defaults to the widest gallery image
--      tagline = "One line pitch.",
--      tags = {"Levels 1-3", "4-6 heroes"},
--      publisher = "MCDM",
--      aboutTitle = "A hunt through the snow",
--      about = "Longer description.",  --defaults to the item's details text
--      media = {
--          --tab 1: the cover with sample pages fanned out behind it.
--          book = {cover = "<guid>", pages = {"<guid>", ...}},
--          --tab 2: every map in turn. x/y of a pin are fractions of the map
--          --image from its TOP-left.
--          maps = {
--              {image = "<guid>", name = "Temple Olea",
--               pins = {{label = "The ford", x = 0.4, y = 0.7}}},
--          },
--          --tabs 3-5: art, each shown whole.
--          art = { {image = "<guid>", caption = "The winter wood", label = "Art"} },
--      },
--      cast = { {image = "<guid>", name = "Captain Moon", role = "Ally"} },
--  }
--The config is stored on the shop item as item.adventurePage (authored in the
--shop admin, ShopAdmin/AdventurePageEditor.lua). AdventurePage.SetDevFixture
--holds sample configs in memory, used when an item has none saved, so the page
--can be reviewed without saving anything.

AdventurePage = {}

local g_devFixtures = {}

function AdventurePage.SetDevFixture(itemid, cfg)
    g_devFixtures[itemid] = cfg
end

--The page config for a shop item, or nil. The engine field is read through
--pcall: an unknown member on engine userdata raises on older engines.
function AdventurePage.Read(item)
    if item == nil or item.itemType ~= "Module" then
        return nil
    end
    local cfg = nil
    pcall(function() cfg = item.adventurePage end)
    if type(cfg) ~= "table" then
        cfg = g_devFixtures[item.id]
    end
    return cfg
end

function AdventurePage.Has(item)
    return AdventurePage.Read(item) ~= nil
end

--Image size lookups for any image id a page stores: asset guids, and the
--"md5:<blob>" ids Fill from adventure writes. Two engine details this covers:
--the size lookup wants a blob id WITHOUT the "md5:" prefix (bgimage wants it
--WITH), and a lookup gives up silently after ~1000 frames, which a large image
--on a slow connection can outlast -- so it is retried a few times.
--Calls callback(dims) at most once. Something must be showing the image (a
--panel's bgimage) for it to download; the lookup alone does not fetch it.
local g_dimsRetries = 4
local g_dimsRetrySeconds = 12

function AdventurePage.ImageDimensions(imageid, callback)
    if type(imageid) ~= "string" or imageid == "" then
        return
    end
    local lookup = imageid
    if lookup:sub(1, 4) == "md5:" then
        lookup = lookup:sub(5)
    end
    local answered = false
    local function Try(attempt)
        gui.GetImageDimensionsCallback(lookup, function(dims)
            if answered then
                return
            end
            answered = true
            callback(dims)
        end)
        dmhub.Schedule(g_dimsRetrySeconds, function()
            if mod.unloaded or answered or attempt >= g_dimsRetries then
                return
            end
            Try(attempt + 1)
        end)
    end
    Try(1)
end

--------------------------------------------------------------------------------
--Fill from adventure: builds a first-draft page config from the module
--itself, for the admin to review and adjust. Reads the module record
--(description, and the image assets it ships -- publishingProperties'
--included/published assets) and the module snapshot (its characters), none
--of which installs anything. Picks by shape and size:
--  key art   -- the largest wide image
--  art tabs  -- the next largest wide images
--  book      -- the shop item's portrait gallery image as the cover, with
--               the module's page-shaped (tall, ~0.7 aspect) images fanned
--               behind it
--  cast      -- named characters, one per portrait, off-token art preferred
--  text      -- the module description; tagline and tags picked out of it
--Adventure maps are usually built from placed objects rather than one image,
--so maps are left for the admin to add.
--------------------------------------------------------------------------------
local g_autoFillMinSide = 1500     --images smaller than this are tokens/icons
local g_autoFillWaitSeconds = 20   --give up on images that never resolve

local g_numberWords = {one = 1, two = 2, three = 3, four = 4, five = 5, six = 6, seven = 7, eight = 8, nine = 9, ten = 10}

local function WordNumber(word)
    if word == nil then
        return nil
    end
    return tonumber(word) or g_numberWords[string.lower(word)]
end

--Tags from the usual adventure blurb: "a quest for 2nd-level heroes",
--"one to two session", "up to six Victories". Anything not found is skipped.
local function TagsFromDetails(details)
    local tags = {}
    local level = details:match("(%d+)%a%a%-level")
    if level ~= nil then
        tags[#tags + 1] = "Level " .. level
    end
    local a, b = details:match("(%w+) to (%w+)[%s%-]+sessions?")
    if a == nil then
        a, b = details:match("(%w+) or (%w+)[%s%-]+sessions?")
    end
    if WordNumber(a) ~= nil and WordNumber(b) ~= nil then
        tags[#tags + 1] = string.format("%d-%d sessions", WordNumber(a), WordNumber(b))
    else
        local one = details:match("(%w+)[%s%-]+sessions?")
        if WordNumber(one) ~= nil then
            tags[#tags + 1] = string.format("%d %s", WordNumber(one), cond(WordNumber(one) == 1, "session", "sessions"))
        end
    end
    local victories = details:match("[Uu]p to (%w+) [Vv]ictories")
    if WordNumber(victories) ~= nil then
        tags[#tags + 1] = string.format("Up to %d Victories", WordNumber(victories))
    end
    return tags
end

--Sentences that describe the product rather than the story.
local g_blurbWords = {"level", "session", "intended", "director", "assumes", "players", "adventure for"}
local g_taglineMaxLength = 140

--A one-line pitch: the first short sentence that tells the story rather than
--the format, looking past the first paragraph (usually the level/format
--blurb) before falling back to it. Empty when nothing qualifies.
local function TaglineFromDetails(details)
    local paragraphs = {}
    for para in (details .. "\n\n"):gmatch("(.-)\r?\n%s*\r?\n") do
        para = para:match("^%s*(.-)%s*$")
        if para ~= "" then
            paragraphs[#paragraphs + 1] = para
        end
    end
    local order = {}
    for i = 2, #paragraphs do
        order[#order + 1] = paragraphs[i]
    end
    order[#order + 1] = paragraphs[1]

    for _, para in ipairs(order) do
        for sentence in (para .. " "):gmatch("(.-[%.!%?])%s") do
            sentence = sentence:match("^%s*(.-)%s*$")
            local lower = string.lower(sentence)
            local blurb = false
            for _, word in ipairs(g_blurbWords) do
                if lower:find(word, 1, true) then
                    blurb = true
                end
            end
            if not blurb and #sentence <= g_taglineMaxLength then
                return sentence
            end
        end
    end
    return ""
end

--Looks up the size of every id; calls done(list of {id, w, h}) once all have
--answered or the wait runs out. Ids that are not images never answer.
local function ResolveImages(ids, done)
    local found = {}
    local pending = #ids
    local finished = false
    local function Finish()
        if finished then
            return
        end
        finished = true
        done(found)
    end
    if pending == 0 then
        Finish()
        return
    end
    for _, id in ipairs(ids) do
        gui.GetImageDimensionsCallback(id, function(dims)
            if dims ~= nil and (dims.width or 0) > 0 and (dims.height or 0) > 0 then
                found[#found + 1] = {id = id, w = dims.width, h = dims.height}
            end
            pending = pending - 1
            if pending == 0 then
                Finish()
            end
        end)
    end
    dmhub.Schedule(g_autoFillWaitSeconds, function()
        if not mod.unloaded then
            Finish()
        end
    end)
end

--The module's image ids only resolve on a machine that has its snapshot, so a
--shopper who has not bought it could never see them. Every image asset is
--also a public, content-addressed blob, which any client loads through an
--"md5:<blob>" id with no asset record needed (as chat attachments do). Swap
--each asset id for that form; ids it cannot resolve are left as they are.
local function PortableImageId(id)
    if type(id) ~= "string" or id == "" or id:sub(1, 4) == "md5:" then
        return id
    end
    local blob = nil
    pcall(function()
        local asset = assets.imagesTable[id]
        if asset ~= nil then
            blob = asset.imageid
        end
    end)
    if type(blob) == "string" and blob ~= "" then
        return "md5:" .. blob
    end
    return id
end

local function PortableConfig(cfg)
    cfg.heroImage = PortableImageId(cfg.heroImage)
    cfg.media.book.cover = PortableImageId(cfg.media.book.cover)
    for i, page in ipairs(cfg.media.book.pages) do
        cfg.media.book.pages[i] = PortableImageId(page)
    end
    for _, list in ipairs({cfg.media.maps, cfg.media.art, cfg.cast}) do
        for _, entry in ipairs(list) do
            entry.image = PortableImageId(entry.image)
        end
    end
    return cfg
end

--Builds the draft and calls callback(cfg), or callback(nil, errorMessage).
function AdventurePage.AutoFill(item, callback)
    local moduleid = item.assetid
    if item.itemType ~= "Module" or moduleid == nil or moduleid == "" then
        callback(nil, "This item is not linked to a module.")
        return
    end

    module.DownloadModuleInfo{
        moduleid = moduleid,
        failure = function(msg)
            callback(nil, "Could not read the module: " .. tostring(msg))
        end,
        success = function(info)
            local details, props = "", nil
            pcall(function() details = info.details or "" end)
            pcall(function() props = info.publishingProperties end)

            local idSet, ids = {}, {}
            for _, key in ipairs({"includedAssets", "publishedAssets"}) do
                if type(props) == "table" and type(props[key]) == "table" then
                    for id, _ in pairs(props[key]) do
                        if not idSet[id] then
                            idSet[id] = true
                            ids[#ids + 1] = id
                        end
                    end
                end
            end

            local cfg = {
                heroImage = "",
                tagline = TaglineFromDetails(details),
                tags = TagsFromDetails(details),
                publisher = "MCDM",
                aboutTitle = "",
                about = details,
                media = {book = {cover = "", pages = {}}, maps = {}, art = {}},
                cast = {},
            }

            local function FillImages(nextStep)
                ResolveImages(ids, function(images)
                    local wide, tall = {}, {}
                    for _, image in ipairs(images) do
                        local aspect = image.w / image.h
                        if math.max(image.w, image.h) >= g_autoFillMinSide then
                            if aspect >= 1.3 then
                                wide[#wide + 1] = image
                            elseif aspect >= 0.6 and aspect <= 0.8 then
                                tall[#tall + 1] = image
                            end
                        end
                    end
                    --largest first; ties by id so the result is repeatable.
                    local function Bigger(a, b)
                        if a.w * a.h ~= b.w * b.h then
                            return a.w * a.h > b.w * b.h
                        end
                        return a.id < b.id
                    end
                    table.sort(wide, Bigger)
                    table.sort(tall, Bigger)

                    if wide[1] ~= nil then
                        cfg.heroImage = wide[1].id
                    end
                    for i = 2, math.min(#wide, 4) do
                        cfg.media.art[#cfg.media.art + 1] = {image = wide[i].id, caption = "", label = "Art"}
                    end
                    --a single page-shaped image is usually another copy of the
                    --cover; fanning needs at least two real pages.
                    if #tall >= 2 then
                        for i = 1, math.min(#tall, 6) do
                            cfg.media.book.pages[#cfg.media.book.pages + 1] = tall[i].id
                        end
                    end

                    --the cover: the shop item's own portrait-shaped image.
                    local gallery = item.images or {}
                    local candidates = #gallery
                    if candidates == 0 then
                        nextStep()
                        return
                    end
                    for _, imageid in ipairs(gallery) do
                        AdventurePage.ImageDimensions(imageid, function(dims)
                            if cfg.media.book.cover == "" and dims ~= nil and (dims.height or 0) > 0 and dims.width / dims.height < 1 then
                                cfg.media.book.cover = imageid
                            end
                            candidates = candidates - 1
                            if candidates == 0 then
                                nextStep()
                            end
                        end)
                    end
                end)
            end

            local function FillCast(nextStep)
                if module.DownloadModuleSnapshot == nil then
                    nextStep()
                    return
                end
                module.DownloadModuleSnapshot{
                    moduleid = moduleid,
                    failure = function()
                        nextStep()
                    end,
                    success = function(snapshot)
                        local seen = {}
                        local members = {}
                        for _, tok in pairs(snapshot.characters or {}) do
                            local name, portrait = nil, nil
                            pcall(function() name = tok.name end)
                            pcall(function() portrait = tok.offTokenPortrait end)
                            if portrait == nil or portrait == "" then
                                pcall(function() portrait = tok.portrait end)
                            end
                            --"High Elf Quiver 3" and its siblings are one cast member.
                            if type(name) == "string" and name ~= "" then
                                name = name:gsub("%s+%d+$", "")
                            end
                            local usable = type(name) == "string" and name ~= "" and type(portrait) == "string"
                                and portrait ~= "" and not portrait:find("DEFAULT")
                            if usable and not seen[name] and not seen[portrait] then
                                seen[name] = true
                                seen[portrait] = true
                                members[#members + 1] = {image = portrait, name = name, role = ""}
                            end
                        end
                        table.sort(members, function(a, b) return a.name < b.name end)
                        for i = 1, math.min(#members, 5) do
                            cfg.cast[#cfg.cast + 1] = members[i]
                        end
                        nextStep()
                    end,
                }
            end

            --The snapshot goes first: besides the cast, downloading it is what
            --makes the module's own images resolvable on this machine.
            FillCast(function()
                FillImages(function()
                    if not mod.unloaded then
                        callback(PortableConfig(cfg))
                    end
                end)
            end)
        end,
    }
end

--Palette and type. Gold is the shop's own accent (its checkout button).
local g_accent = "srgb:#f6ddb6"
local g_textStrong = "#f3ecdfff"
local g_textBody = "#d9d2c5ff"
local g_textMuted = "#9a958cff"
local g_pageBg = "#1c1c1eff"
local g_serif = "Berling"

local function ReduceMotion()
    local access = nil
    pcall(function() access = ThemeEngine.GetAccessibility() end)
    return access ~= nil and access.reduceMotion == true
end

local function PriceText(item)
    if item.price <= 0 then
        return "Free"
    end
    return string.format("$%d.%02d", math.tointeger(math.floor(item.price / 100)), math.tointeger(item.price % 100))
end

--The image window that COVERS a box of boxW x boxH, zoomed in by `zoom`
--(1 = plain cover) and positioned by u/v (0..1 across the spare travel).
--The window's aspect always equals the box's, so art is never stretched.
--Returns the imageRect (engine y is bottom-up) and the window's top-left and
--size as top-down fractions of the image, for placing things on the art.
local function CoverWindow(boxW, boxH, imageW, imageH, zoom, u, v)
    local boxAspect = boxW / boxH
    local imageAspect = imageW / imageH
    local wFrac, hFrac
    if imageAspect > boxAspect then
        hFrac = 1
        wFrac = boxAspect / imageAspect
    else
        wFrac = 1
        hFrac = imageAspect / boxAspect
    end
    wFrac = wFrac / zoom
    hFrac = hFrac / zoom
    local left = (1 - wFrac) * u
    local top = (1 - hFrac) * v
    return {x1 = left, x2 = left + wFrac, y1 = 1 - top - hFrac, y2 = 1 - top}, left, top, wFrac, hFrac
end

--Shows `imageid` on `element` cover-cropped to boxW x boxH once its size is
--known; v = 0 keeps the top of the art (faces), 0.5 centres it.
local function ShowCovered(element, imageid, boxW, boxH, v)
    element.bgimage = imageid
    AdventurePage.ImageDimensions(imageid, function(dims)
        if mod.unloaded or not element.valid or element.bgimage ~= imageid then
            return
        end
        if dims == nil or (dims.width or 0) <= 0 or (dims.height or 0) <= 0 then
            return
        end
        local rect = CoverWindow(boxW, boxH, dims.width, dims.height, 1, 0.5, v or 0.5)
        element.selfStyle.imageRect = rect
        element.selfStyle.bgcolor = "#ffffffff"
    end)
end

--Add to Cart / Remove from Cart / Add as Gift, in the shop's gold. Reacts to
--the same refreshItem / refreshCart events the shop fires down the details
--page, and hands presses up with the same addToCart / removeFromCart events.
local function MakeBuyButton(width, showPrice)
    return gui.Label{
        classes = {"itemButton", "checkoutButton", "collapsedWhenInventory", "collapseOnGift", "collapseOnNoCommerce"},
        width = width,
        height = 44,
        fontSize = 15,
        fontWeight = "semibold",
        --dark on the gold fill; the shop style leaves it too faint to read.
        color = "#1c1c1eff",
        vmargin = 0,
        data = {item = nil, inCart = false},

        refreshItem = function(element, item)
            element.data.item = item
        end,

        refreshCart = function(element, shoppingCart)
            local item = element.data.item
            if item == nil then
                return
            end
            local inCart = shoppingCart[item.id] == true
            element.data.inCart = inCart
            if inCart then
                element.text = "Remove from Cart"
            elseif shop:ItemInInventory(item.id) then
                element.text = cond(showPrice, "Add as Gift - " .. PriceText(item), "Add as Gift")
            else
                element.text = cond(showPrice, "Add to Cart - " .. PriceText(item), "Add to Cart")
            end
        end,

        press = function(element)
            local item = element.data.item
            if item == nil then
                return
            end
            if element.data.inCart then
                element:FireEventOnParents("removeFromCart", item)
            else
                element:FireEventOnParents("addToCart", item)
                analytics.Event{type = "shopAddCart", itemid = item.id}
            end
        end,
    }
end

--The default key art: the widest gallery image, since hero art is landscape.
local function PickHeroImage(item, cfg, callback)
    if type(cfg.heroImage) == "string" and cfg.heroImage ~= "" then
        callback(cfg.heroImage)
        return
    end
    local images = item.images or {}
    local best, bestAspect, pending = images[1], 0, #images
    if pending == 0 then
        callback(nil)
        return
    end
    for _, imageid in ipairs(images) do
        AdventurePage.ImageDimensions(imageid, function(dims)
            if dims ~= nil and (dims.height or 0) > 0 and dims.width / dims.height > bestAspect then
                best = imageid
                bestAspect = dims.width / dims.height
            end
            pending = pending - 1
            if pending == 0 then
                callback(best)
            end
        end)
    end
end

--------------------------------------------------------------------------------
--Hero: full-bleed key art drifting very slowly, a left-hand scrim, and the
--title, pitch, tags and buy button over it.
--------------------------------------------------------------------------------
local function MakeHero(width, height)
    local m_dims = nil
    local m_time = 0

    local art
    art = gui.Panel{
        floating = true,
        width = width,
        height = height,
        bgimage = "panels/square.png",
        bgcolor = "#ffffff00",
        interactable = false,

        think = function(element)
            if m_dims == nil then
                return
            end
            m_time = m_time + element.thinkTime
            --a very slow, shallow drift: a few percent of zoom, one cycle
            --every couple of minutes.
            --v stays in the upper part of the art: key art is usually taller
            --than this strip, and faces sit high in the frame.
            local u = 0.5 + 0.5 * math.sin(m_time / 19)
            local v = 0.25 + 0.15 * math.sin(m_time / 27)
            element.selfStyle.imageRect = CoverWindow(width, height, m_dims.width, m_dims.height, 1.06, u, v)
        end,

        showArt = function(element, imageid)
            m_dims = nil
            element.thinkTime = nil
            element.selfStyle.bgcolor = "#ffffff00"
            if imageid == nil then
                return
            end
            element.bgimage = imageid
            AdventurePage.ImageDimensions(imageid, function(dims)
                if mod.unloaded or not element.valid or element.bgimage ~= imageid then
                    return
                end
                if dims == nil or (dims.width or 0) <= 0 or (dims.height or 0) <= 0 then
                    return
                end
                m_dims = dims
                element.selfStyle.imageRect = CoverWindow(width, height, dims.width, dims.height, 1.06, 0.5, 0.25)
                element.selfStyle.bgcolor = "#ffffffff"
                if not ReduceMotion() then
                    element.thinkTime = 0.05
                end
            end)
        end,
    }

    --Dark from the left edge so the copy always reads, clear by the right
    --third so the art carries the page. bgcolor gives the hue, the gradient
    --the alpha.
    local sideScrim = gui.Panel{
        floating = true,
        width = width,
        height = height,
        interactable = false,
        bgimage = "panels/square.png",
        bgcolor = g_pageBg,
        gradient = gui.Gradient{
            point_a = {x = 0, y = 0.5},
            point_b = {x = 1, y = 0.5},
            stops = {
                {position = 0, color = core.Color{r = 1, g = 1, b = 1, a = 0.97}},
                {position = 0.35, color = core.Color{r = 1, g = 1, b = 1, a = 0.88}},
                {position = 0.6, color = core.Color{r = 1, g = 1, b = 1, a = 0.35}},
                {position = 0.8, color = core.Color{r = 1, g = 1, b = 1, a = 0}},
            },
        },
    }

    --Melts the hero's bottom edge into the page instead of a hard line.
    --Gradient position 0 is the BOTTOM of the panel.
    local bottomScrim = gui.Panel{
        floating = true,
        width = width,
        height = math.floor(height * 0.35),
        valign = "bottom",
        interactable = false,
        bgimage = "panels/square.png",
        bgcolor = g_pageBg,
        gradient = gui.Gradient{
            point_a = {x = 0.5, y = 0},
            point_b = {x = 0.5, y = 1},
            stops = {
                {position = 0, color = core.Color{r = 1, g = 1, b = 1, a = 1}},
                {position = 1, color = core.Color{r = 1, g = 1, b = 1, a = 0}},
            },
        },
    }

    local title = gui.Label{
        fontFace = g_serif,
        fontSize = 56,
        color = g_textStrong,
        width = 560,
        height = "auto",
        textAlignment = "left",
    }

    local tagline = gui.Label{
        fontSize = 18,
        fontWeight = "light",
        color = g_textBody,
        width = 520,
        height = "auto",
        textAlignment = "left",
        tmargin = 8,
    }

    local tagsRow = gui.Panel{
        flow = "horizontal",
        width = 560,
        height = "auto",
        tmargin = 18,
    }

    local publisher = gui.Label{
        fontSize = 14,
        color = g_textMuted,
        width = "auto",
        height = "auto",
        valign = "center",
        lmargin = 18,
    }

    return gui.Panel{
        width = width,
        height = height,
        flow = "none",
        clip = true,
        bgimage = "panels/square.png",
        bgcolor = g_pageBg,

        art,
        sideScrim,
        bottomScrim,

        gui.Panel{
            floating = true,
            flow = "vertical",
            width = 600,
            height = "auto",
            halign = "left",
            valign = "bottom",
            x = 56,
            y = -52,

            title,
            tagline,
            tagsRow,
            gui.Panel{
                flow = "horizontal",
                width = "auto",
                height = "auto",
                tmargin = 26,
                MakeBuyButton(280, true),
                publisher,
            },
        },

        showPage = function(element, item, cfg)
            title.text = item.name or ""
            tagline.text = cfg.tagline or ""
            tagline:SetClass("collapsed", (cfg.tagline or "") == "")
            publisher.text = cond((cfg.publisher or "") ~= "", "By " .. (cfg.publisher or ""), "")

            local chips = {}
            for i, tag in ipairs(cfg.tags or {}) do
                chips[#chips + 1] = gui.Label{
                    text = tag,
                    fontSize = 13,
                    color = g_textBody,
                    width = "auto",
                    height = 28,
                    hpad = 14,
                    borderBox = true,
                    textAlignment = "center",
                    lmargin = cond(i == 1, 0, 8),
                    bgimage = "panels/square.png",
                    bgcolor = "#00000059",
                    borderWidth = 1,
                    borderColor = "#ffffff38",
                    cornerRadius = 14,
                }
            end
            tagsRow.children = chips
            tagsRow:SetClass("collapsed", #chips == 0)

            PickHeroImage(item, cfg, function(imageid)
                if mod.unloaded or not art.valid then
                    return
                end
                art:FireEvent("showArt", imageid)
            end)
        end,
    }
end

--------------------------------------------------------------------------------
--Content counts: the module's contentSummary, fetched once per module with
--module.DownloadModuleInfo (the module record only -- nothing is downloaded
--or installed). Shared by the media captions and the buy box.
--------------------------------------------------------------------------------

--Counts by module id: {lowercased summary type = item count} once fetched,
--false while a fetch is in flight. A failed fetch clears the entry so the
--next open retries.
local g_countsCache = {}
local g_countsWaiting = {}

--Calls callback(counts) once the module's counts are known. Callers check
--their own panel is still valid inside the callback.
local function FetchCounts(moduleid, callback)
    if moduleid == nil or moduleid == "" or module.DownloadModuleInfo == nil then
        return
    end
    local cached = g_countsCache[moduleid]
    if type(cached) == "table" then
        callback(cached)
        return
    end
    g_countsWaiting[moduleid] = g_countsWaiting[moduleid] or {}
    table.insert(g_countsWaiting[moduleid], callback)
    if cached == false then
        return
    end
    g_countsCache[moduleid] = false
    module.DownloadModuleInfo{
        moduleid = moduleid,
        success = function(info)
            local summary = nil
            pcall(function() summary = info.contentSummary end)
            local counts = {}
            for _, entry in ipairs(summary or {}) do
                local kind = string.lower(tostring(entry.type or ""))
                local n = 0
                for _ in ipairs(entry.items or {}) do
                    n = n + 1
                end
                counts[kind] = (counts[kind] or 0) + n
            end
            g_countsCache[moduleid] = counts
            local waiting = g_countsWaiting[moduleid] or {}
            g_countsWaiting[moduleid] = nil
            if mod.unloaded then
                return
            end
            for _, f in ipairs(waiting) do
                f(counts)
            end
        end,
        failure = function(msg)
            g_countsCache[moduleid] = nil
            g_countsWaiting[moduleid] = nil
        end,
    }
end

local function CountOf(counts, types)
    local total = 0
    for _, kind in ipairs(types) do
        total = total + (counts[kind] or 0)
    end
    return total
end

local function Plural(n, one, many)
    return string.format("%d %s", n, cond(n == 1, one, many))
end

local g_mapTypes = {"map", "maps"}
local g_pdfTypes = {"pdfdocument"}

--------------------------------------------------------------------------------
--Media viewer: a stage plus a row of labelled tabs, one per slide:
--  the book -- the cover, with pages fanned out behind it ("1 PDF included")
--  maps     -- a slow pan over each map in turn, crossfading between them
--  art      -- up to three pieces, each shown whole (letterboxed, never cropped)
--------------------------------------------------------------------------------
local g_panPeriod = 40          --seconds for one sweep across a map and back
local g_panVerticalRatio = 0.63 --vertical drift rate, so the path wanders
local g_panZoom = 1.3           --past a plain cover fit, so there is room to drift
local g_mapHoldTime = 9         --seconds each map shows before the next fades in
local g_mapFadeTime = 1.5
local g_pinInset = 0.1          --pins show only inside this margin of the frame
local g_maxArt = 3

--The caption band along the stage's bottom: a scrim that melts into the art,
--a headline ("3 maps included") and an optional smaller line under it.
local function MakeCaption(width, stageH)
    local headline = gui.Label{
        fontFace = g_serif,
        fontSize = 24,
        color = g_textStrong,
        width = "auto",
        height = "auto",
        halign = "center",
    }
    local subline = gui.Label{
        fontSize = 14,
        color = g_textBody,
        width = "auto",
        height = "auto",
        halign = "center",
        tmargin = 2,
    }
    return gui.Panel{
        floating = true,
        flow = "vertical",
        width = width,
        height = 170,
        valign = "bottom",
        interactable = false,
        bgimage = "panels/square.png",
        bgcolor = "#000000ff",
        --position 0 is the BOTTOM of the panel.
        gradient = gui.Gradient{
            point_a = {x = 0.5, y = 0},
            point_b = {x = 0.5, y = 1},
            stops = {
                {position = 0, color = core.Color{r = 1, g = 1, b = 1, a = 0.92}},
                {position = 0.45, color = core.Color{r = 1, g = 1, b = 1, a = 0.72}},
                {position = 1, color = core.Color{r = 1, g = 1, b = 1, a = 0}},
            },
        },
        gui.Panel{
            flow = "vertical",
            width = "auto",
            height = "auto",
            halign = "center",
            valign = "bottom",
            bmargin = 22,
            headline,
            subline,
        },
        setCaption = function(element, main, sub)
            headline.text = main or ""
            subline.text = sub or ""
            subline:SetClass("collapsed", (sub or "") == "")
            element:SetClass("collapsed", (main or "") == "" and (sub or "") == "")
        end,
    }
end

--Tab 1: the cover front and centre with pages fanned out behind it,
--alternating left and right, each step further out, tilted and darker, so the
--spread fills the frame.
local function MakeBookSlide(width, stageH)
    local caption = MakeCaption(width, stageH)
    local spread = gui.Panel{
        floating = true,
        flow = "none",
        width = width,
        height = stageH,
        interactable = false,
    }

    return gui.Panel{
        floating = true,
        flow = "none",
        width = width,
        height = stageH,

        spread,
        caption,

        showSlide = function(element, slide, counts)
            local pdfs = CountOf(counts or {}, g_pdfTypes)
            if pdfs > 0 then
                caption:FireEvent("setCaption", Plural(pdfs, "PDF", "PDFs") .. " included", slide.subtitle)
            else
                caption:FireEvent("setCaption", slide.subtitle or "", nil)
            end
        end,

        buildSlide = function(element, slide)
            local cover = slide.cover
            --the spread is sized from the cover, but nothing shows the cover
            --until then; an invisible bgimage starts its download.
            spread.bgimage = cover
            spread.selfStyle.bgcolor = "#ffffff00"
            AdventurePage.ImageDimensions(cover, function(dims)
                if mod.unloaded or not spread.valid then
                    return
                end
                if dims == nil or (dims.width or 0) <= 0 or (dims.height or 0) <= 0 then
                    return
                end
                --every page shares the cover's size and shape.
                local pageH = math.floor(stageH * 0.8)
                local pageW = math.floor(pageH * dims.width / dims.height)
                local lift = -30

                local function Page(imageid, x, rotate, brightness)
                    local page = gui.Panel{
                        floating = true,
                        halign = "center",
                        valign = "center",
                        x = x,
                        y = lift,
                        width = pageW,
                        height = pageH,
                        rotate = rotate,
                        bgimage = "panels/square.png",
                        bgcolor = "#ffffff10",
                        interactable = false,
                    }
                    --set through selfStyle: brightness given at construction does not stick.
                    page.selfStyle.brightness = brightness
                    page.selfStyle.saturation = 0.6 + 0.4 * brightness
                    ShowCovered(page, imageid, pageW, pageH, 0.5)
                    return page
                end

                --a soft dark slab under a page, offset down-right, as its shadow.
                local function Shadow(x, rotate, alpha)
                    return gui.Panel{
                        floating = true,
                        halign = "center",
                        valign = "center",
                        x = x + 10,
                        y = lift + 14,
                        width = pageW,
                        height = pageH,
                        rotate = rotate,
                        bgimage = "panels/square.png",
                        bgcolor = string.format("#000000%02x", math.floor(alpha * 255)),
                        cornerRadius = 4,
                        interactable = false,
                    }
                end

                --pages outermost first so each nearer page draws over the last.
                local pages = slide.pages or {}
                local steps = math.ceil(#pages / 2)
                local children = {}
                for step = steps, 1, -1 do
                    for side = -1, 1, 2 do
                        local index = (step - 1) * 2 + cond(side < 0, 1, 2)
                        local imageid = pages[index]
                        if imageid ~= nil then
                            local x = side * step * pageW * 0.46
                            local rotate = -side * step * 3.5
                            children[#children + 1] = Shadow(x, rotate, 0.35)
                            children[#children + 1] = Page(imageid, x, rotate, 0.55 - 0.15 * (step - 1))
                        end
                    end
                end
                children[#children + 1] = Shadow(0, 0, 0.55)
                children[#children + 1] = Page(cover, 0, 0, 1)
                spread.children = children
            end)
        end,
    }
end

--Tab 2: every map in turn. Each map is its own layer (the art plus its place
--names) that drifts slowly; after g_mapHoldTime the next layer fades in over
--it. Only the showing layer and the one fading out are updated.
local function MakeMapsSlide(width, stageH)
    local caption = MakeCaption(width, stageH)
    local m_maps = {}
    local m_layers = {}
    local m_current = 1
    local m_previous = nil
    local m_hold = 0
    local m_count = 0
    local m_still = false

    local function MakeLayer(map)
        local state = {dims = nil, time = 0, pins = {}}

        local image = gui.Panel{
            floating = true,
            width = width,
            height = stageH,
            interactable = false,
            bgimage = "panels/square.png",
            bgcolor = "#ffffff00",
        }

        for i, pin in ipairs(map.pins or {}) do
            state.pins[i] = gui.Label{
                classes = {"adventurePin"},
                floating = true,
                halign = "left",
                valign = "top",
                interactable = false,
                text = pin.label or "",
                fontFace = g_serif,
                fontSize = 18,
                color = g_textStrong,
                width = "auto",
                height = "auto",
                hpad = 12,
                vpad = 4,
                borderBox = true,
                bgimage = "panels/square.png",
                bgcolor = "#000000b3",
                borderWidth = 1,
                borderColor = "#f6ddb659",
                cornerRadius = 4,
            }
        end

        local layer = gui.Panel{
            classes = {"adventureMapLayer"},
            floating = true,
            flow = "none",
            width = width,
            height = stageH,
            interactable = false,
            data = {state = state, map = map},
            children = {image, table.unpack(state.pins)},
        }

        --Positions the window and the pins for this layer's own clock.
        state.apply = function()
            if state.dims == nil then
                return
            end
            local u, v = 0.5, 0.5
            if not m_still then
                --cosine ease: slows to a stop at each end of the sweep.
                local phase = (state.time / g_panPeriod) * 2 * math.pi
                u = 0.5 - 0.5 * math.cos(phase)
                v = 0.5 - 0.5 * math.cos(phase * g_panVerticalRatio)
            end
            local rect, left, top, wFrac, hFrac = CoverWindow(width, stageH, state.dims.width, state.dims.height, g_panZoom, u, v)
            image.selfStyle.imageRect = rect
            for i, pinDef in ipairs(map.pins or {}) do
                local label = state.pins[i]
                local px = ((pinDef.x or 0.5) - left) / wFrac
                local py = ((pinDef.y or 0.5) - top) / hFrac
                label.x = px * width - label.renderedWidth * 0.5
                label.y = py * stageH - label.renderedHeight * 0.5
                label:SetClass("pinShown", px > g_pinInset and px < 1 - g_pinInset and py > g_pinInset and py < 1 - g_pinInset)
            end
        end

        image.bgimage = map.image
        AdventurePage.ImageDimensions(map.image, function(dims)
            if mod.unloaded or not image.valid then
                return
            end
            if dims == nil or (dims.width or 0) <= 0 or (dims.height or 0) <= 0 then
                return
            end
            state.dims = dims
            state.apply()
            image.selfStyle.bgcolor = "#ffffffff"
        end)

        return layer
    end

    local function ShowCaption()
        local map = m_maps[m_current]
        local total = math.max(m_count, #m_maps)
        caption:FireEvent("setCaption", Plural(total, "map", "maps") .. " included", map and map.name)
    end

    local function Select(index)
        m_previous = m_current
        m_current = index
        m_hold = 0
        for i, layer in ipairs(m_layers) do
            layer:SetClass("mapShown", i == m_current)
        end
        local state = m_layers[m_current].data.state
        state.time = 0
        state.apply()
        ShowCaption()
    end

    local layerHost = gui.Panel{
        floating = true,
        flow = "none",
        width = width,
        height = stageH,
        interactable = false,
        styles = {
            {selectors = {"adventureMapLayer"}, opacity = 0, transitionTime = g_mapFadeTime},
            {selectors = {"adventureMapLayer", "mapShown"}, opacity = 1, transitionTime = g_mapFadeTime},
        },
    }

    return gui.Panel{
        floating = true,
        flow = "none",
        width = width,
        height = stageH,

        layerHost,
        caption,

        --Runs only while this slide is the visible one: collapsed slides (and
        --a collapsed details page) do not think.
        think = function(element)
            if #m_layers == 0 then
                return
            end
            local dt = element.thinkTime
            if not m_still then
                local state = m_layers[m_current].data.state
                state.time = state.time + dt
                state.apply()
                --keep the outgoing map drifting until it has faded away.
                if m_previous ~= nil and m_previous ~= m_current and m_hold < g_mapFadeTime then
                    local prev = m_layers[m_previous].data.state
                    prev.time = prev.time + dt
                    prev.apply()
                end
            end
            if #m_layers > 1 and not m_still then
                m_hold = m_hold + dt
                if m_hold >= g_mapHoldTime then
                    Select((m_current % #m_layers) + 1)
                end
            end
        end,

        buildSlide = function(element, slide)
            m_maps = {}
            for _, map in ipairs(slide.maps or {}) do
                if type(map.image) == "string" and map.image ~= "" then
                    m_maps[#m_maps + 1] = map
                end
            end
            m_layers = {}
            for i, map in ipairs(m_maps) do
                m_layers[i] = MakeLayer(map)
            end
            layerHost.children = m_layers
            m_current = 1
            m_previous = nil
            m_hold = 0
        end,

        showSlide = function(element, slide, counts)
            m_count = CountOf(counts or {}, g_mapTypes)
            m_still = ReduceMotion()
            element.thinkTime = 0.03
            if #m_layers > 0 then
                Select(1)
            end
        end,
    }
end

--Tabs 3+: one piece of art, shown whole on the dark stage.
local function MakeArtSlide(width, stageH)
    local caption = MakeCaption(width, stageH)
    local image = gui.Panel{
        floating = true,
        halign = "center",
        valign = "center",
        width = width,
        height = stageH,
        interactable = false,
        bgimage = "panels/square.png",
        bgcolor = "#ffffff00",
    }
    return gui.Panel{
        floating = true,
        flow = "none",
        width = width,
        height = stageH,

        image,
        caption,

        buildSlide = function(element, slide)
            image.bgimage = slide.image
            AdventurePage.ImageDimensions(slide.image, function(dims)
                if mod.unloaded or not image.valid then
                    return
                end
                if dims == nil or (dims.width or 0) <= 0 or (dims.height or 0) <= 0 then
                    return
                end
                --fit inside the stage at the art's own aspect: letterboxed, never
                --cropped or stretched.
                local scale = math.min(width / dims.width, stageH / dims.height)
                image.selfStyle.width = math.floor(dims.width * scale)
                image.selfStyle.height = math.floor(dims.height * scale)
                image.selfStyle.bgcolor = "#ffffffff"
            end)
        end,

        showSlide = function(element, slide, counts)
            caption:FireEvent("setCaption", slide.caption or "", nil)
        end,
    }
end

--The slides a page config describes, in tab order, each with the image its
--tab thumbnail shows and the tab's label.
local function SlidesFromConfig(cfg)
    local media = cfg.media or {}
    local slides = {}

    local book = media.book
    if type(book) == "table" and type(book.cover) == "string" and book.cover ~= "" then
        slides[#slides + 1] = {kind = "book", cover = book.cover, pages = book.pages or {}, subtitle = book.subtitle,
                               thumb = book.cover, label = "The book"}
    end

    local maps = {}
    for _, map in ipairs(media.maps or {}) do
        if type(map.image) == "string" and map.image ~= "" then
            maps[#maps + 1] = map
        end
    end
    if #maps > 0 then
        slides[#slides + 1] = {kind = "maps", maps = maps, thumb = maps[1].image, label = "Maps"}
    end

    local artCount = 0
    for _, art in ipairs(media.art or {}) do
        if type(art.image) == "string" and art.image ~= "" and artCount < g_maxArt then
            artCount = artCount + 1
            slides[#slides + 1] = {kind = "art", image = art.image, caption = art.caption,
                                   thumb = art.image, label = art.label or "Art"}
        end
    end

    return slides
end

local function MakeMediaViewer(width, stageH)
    local m_slides = {}
    local m_panels = {}
    local m_counts = {}
    local m_selected = 1
    local m_moduleid = nil

    local stage = gui.Panel{
        width = width,
        height = stageH,
        flow = "none",
        clip = true,
        bgimage = "panels/square.png",
        bgcolor = "#0e0e10ff",
        cornerRadius = 8,
        styles = {
            {selectors = {"adventurePin"}, opacity = 0, transitionTime = 1.2},
            {selectors = {"adventurePin", "pinShown"}, opacity = 1, transitionTime = 1.2},
        },
    }

    local tabGap = 12
    local tabCount = 2 + g_maxArt
    local tabW = math.floor((width - tabGap * (tabCount - 1)) / tabCount)
    local tabH = math.floor(tabW * 9 / 16)

    local tabs = gui.Panel{
        flow = "horizontal",
        width = width,
        height = "auto",
        tmargin = 14,
        styles = {
            {selectors = {"adventureTab"}, brightness = 0.6, borderColor = "#00000000", transitionTime = 0.15},
            {selectors = {"adventureTab", "hover"}, brightness = 1},
            {selectors = {"adventureTab", "selected"}, brightness = 1, borderColor = g_accent},
            {selectors = {"adventureTabLabel"}, color = g_textMuted},
            {selectors = {"adventureTabLabel", "selected"}, color = g_textStrong},
        },
    }

    local function Select(index)
        m_selected = index
        for i, panel in ipairs(m_panels) do
            panel:SetClass("collapsed", i ~= index)
        end
        if m_panels[index] ~= nil then
            m_panels[index]:FireEvent("showSlide", m_slides[index], m_counts)
        end
        tabs:FireEventTree("tabSelected", index)
    end

    local function BuildTabs()
        local children = {}
        for i, slide in ipairs(m_slides) do
            local thumb = gui.Panel{
                classes = {"adventureTab", cond(i == m_selected, "selected")},
                width = tabW,
                height = tabH,
                bgimage = "panels/square.png",
                bgcolor = "#ffffff10",
                borderWidth = 2,
                cornerRadius = 5,
                tabSelected = function(element, index)
                    element:SetClass("selected", index == i)
                end,
            }
            --v = 0 for the book: keep the top of the cover, where its title is.
            ShowCovered(thumb, slide.thumb, tabW, tabH, cond(slide.kind == "book", 0, 0.5))

            children[#children + 1] = gui.Panel{
                flow = "vertical",
                width = tabW,
                height = "auto",
                lmargin = cond(i == 1, 0, tabGap),
                press = function(element)
                    Select(i)
                end,
                thumb,
                gui.Label{
                    classes = {"adventureTabLabel", cond(i == m_selected, "selected")},
                    text = slide.label,
                    fontSize = 13,
                    width = tabW,
                    height = "auto",
                    textAlignment = "left",
                    tmargin = 6,
                    tabSelected = function(element, index)
                        element:SetClass("selected", index == i)
                    end,
                },
            }
        end
        tabs.children = children
        --one slide needs no tabs.
        tabs:SetClass("collapsed", #children <= 1)
    end

    return gui.Panel{
        flow = "vertical",
        width = width,
        height = "auto",

        stage,
        tabs,

        showPage = function(element, item, cfg)
            m_slides = SlidesFromConfig(cfg)
            m_counts = {}
            m_selected = 1
            element:SetClass("collapsed", #m_slides == 0)

            m_panels = {}
            for i, slide in ipairs(m_slides) do
                local panel
                if slide.kind == "book" then
                    panel = MakeBookSlide(width, stageH)
                elseif slide.kind == "maps" then
                    panel = MakeMapsSlide(width, stageH)
                else
                    panel = MakeArtSlide(width, stageH)
                end
                m_panels[i] = panel
            end
            stage.children = m_panels
            for i, panel in ipairs(m_panels) do
                panel:FireEvent("buildSlide", m_slides[i])
            end
            BuildTabs()
            if #m_slides > 0 then
                Select(1)
            end

            --the captions' counts arrive later; re-show the current slide then.
            local moduleid = item.assetid
            m_moduleid = moduleid
            FetchCounts(moduleid, function(counts)
                if mod.unloaded or not element.valid or m_moduleid ~= moduleid then
                    return
                end
                m_counts = counts
                if m_panels[m_selected] ~= nil then
                    m_panels[m_selected]:FireEvent("showSlide", m_slides[m_selected], m_counts)
                end
            end)
        end,
    }
end

--------------------------------------------------------------------------------
--Body, left column: about (in the book's voice) and the cast.
--------------------------------------------------------------------------------
local function SerifHeading(text, size)
    return gui.Label{
        text = text,
        fontFace = g_serif,
        fontSize = size or 28,
        color = g_textStrong,
        width = "auto",
        height = "auto",
        halign = "left",
    }
end

local function MakeCastMember(size, colW)
    local portrait = gui.Panel{
        width = size,
        height = size,
        halign = "center",
        bgimage = "panels/square.png",
        bgcolor = "#ffffff10",
        cornerRadius = size / 2,
        borderWidth = 2,
        borderColor = "#f6ddb640",
    }
    local name = gui.Label{
        fontSize = 15,
        color = g_textStrong,
        width = colW,
        height = "auto",
        textAlignment = "center",
        tmargin = 10,
    }
    local role = gui.Label{
        fontSize = 13,
        color = g_textMuted,
        width = colW,
        height = "auto",
        textAlignment = "center",
    }
    return gui.Panel{
        flow = "vertical",
        width = colW,
        height = "auto",
        valign = "top",
        portrait,
        name,
        role,
        showMember = function(element, member)
            --v = 0: keep the top of the art, where faces usually are.
            ShowCovered(portrait, member.image, size, size, 0)
            name.text = member.name or ""
            role.text = member.role or ""
            role:SetClass("collapsed", (member.role or "") == "")
        end,
    }
end

local function MakeAboutColumn(width)
    local aboutTitle = SerifHeading("", 30)
    local aboutText = gui.Label{
        fontSize = 16,
        fontWeight = "light",
        color = g_textBody,
        width = width,
        height = "auto",
        textAlignment = "left",
        tmargin = 12,
    }

    local maxCast = 5
    local colW = math.floor(width / maxCast)
    local members = {}
    for i = 1, maxCast do
        members[i] = MakeCastMember(116, colW)
    end

    local castSection = gui.Panel{
        flow = "vertical",
        width = width,
        height = "auto",
        tmargin = 40,
        SerifHeading("Meet the cast", 26),
        gui.Panel{
            flow = "horizontal",
            width = width,
            height = "auto",
            tmargin = 18,
            children = members,
        },
    }

    return gui.Panel{
        flow = "vertical",
        width = width,
        height = "auto",
        valign = "top",

        aboutTitle,
        aboutText,
        castSection,

        showPage = function(element, item, cfg)
            aboutTitle.text = cond((cfg.aboutTitle or "") ~= "", cfg.aboutTitle, "About this adventure")
            local about = cfg.about
            if about == nil or about == "" then
                about = item.details or ""
            end
            aboutText.text = about
            aboutText:SetClass("collapsed", about == "")

            local cast = {}
            for _, member in ipairs(cfg.cast or {}) do
                if type(member.image) == "string" and member.image ~= "" and #cast < maxCast then
                    cast[#cast + 1] = member
                end
            end
            castSection:SetClass("collapsed", #cast == 0)
            for i, panel in ipairs(members) do
                panel:SetClass("collapsed", cast[i] == nil)
                if cast[i] ~= nil then
                    panel:FireEvent("showMember", cast[i])
                end
            end
        end,
    }
end

--------------------------------------------------------------------------------
--Body, right column: the buy box -- price, button, what's inside.
--------------------------------------------------------------------------------

--What the module's contentSummary counts become, in display order.
local g_insideDefs = {
    {one = "battle map", many = "battle maps", types = {"map", "maps"}},
    {one = "monster", many = "monsters", types = {"monster"}},
    {one = "character", many = "characters", types = {"character"}},
    {one = "treasure", many = "treasures", types = {"object:tbl_gear"}},
    {one = "handout (PDF)", many = "handouts (PDF)", types = {"pdfdocument"}},
}

local function InsideLines(counts)
    local lines = {}
    for _, def in ipairs(g_insideDefs) do
        local total = CountOf(counts, def.types)
        if total > 0 then
            lines[#lines + 1] = Plural(total, def.one, def.many)
        end
    end
    return lines
end

local function MakeBuyBox(width)
    local price = gui.Label{
        fontFace = g_serif,
        fontSize = 36,
        color = g_textStrong,
        width = "auto",
        height = "auto",
        halign = "left",
        classes = {"collapsedWhenInventory"},
    }

    local insideList = gui.Label{
        fontSize = 15,
        color = g_textBody,
        width = width - 48,
        height = "auto",
        textAlignment = "left",
        tmargin = 8,
    }

    local insideSection = gui.Panel{
        flow = "vertical",
        width = width - 48,
        height = "auto",
        tmargin = 22,
        gui.Panel{
            width = width - 48,
            height = 1,
            bgimage = "panels/square.png",
            bgcolor = "#ffffff1a",
            bmargin = 18,
        },
        gui.Label{
            text = "What's inside",
            uppercase = true,
            fontSize = 12,
            color = g_textMuted,
            width = "auto",
            height = "auto",
            halign = "left",
        },
        insideList,
    }

    local m_moduleid = nil

    local function ShowLines(lines)
        insideList.text = table.concat(lines, "\n")
        insideSection:SetClass("collapsed", #lines == 0)
    end

    return gui.Panel{
        flow = "vertical",
        width = width,
        height = "auto",
        valign = "top",
        pad = 24,
        borderBox = true,
        bgimage = "panels/square.png",
        bgcolor = "#ffffff08",
        borderWidth = 1,
        borderColor = "#ffffff1f",
        cornerRadius = 10,

        price,
        gui.Panel{
            width = width - 48,
            height = "auto",
            tmargin = 14,
            MakeBuyButton(width - 48, false),
        },
        insideSection,

        showPage = function(element, item, cfg)
            price.text = PriceText(item)

            local moduleid = item.assetid
            m_moduleid = moduleid
            insideSection:SetClass("collapsed", true)
            FetchCounts(moduleid, function(counts)
                if mod.unloaded or not element.valid or m_moduleid ~= moduleid then
                    return
                end
                ShowLines(InsideLines(counts))
            end)
        end,
    }
end

--------------------------------------------------------------------------------

--Builds the adventure page for the shop details view. Listens for the
--details page's refreshItem(item) and shows itself only for items that have
--a page config; everything else keeps the generic layout.
--  args.width: the page width (the details view passes its banner width).
function AdventurePage.Create(args)
    local width = args.width
    local rightW = 360
    local gap = 44
    local leftW = width - rightW - gap - 56 * 2

    return gui.Panel{
        classes = {"collapsed"},
        flow = "vertical",
        width = width,
        height = "auto",
        halign = "center",
        valign = "top",
        bgimage = "panels/square.png",
        bgcolor = g_pageBg,

        MakeHero(width, 520),

        gui.Panel{
            width = width - 56 * 2,
            height = "auto",
            halign = "center",
            tmargin = 8,
            MakeMediaViewer(width - 56 * 2, math.floor((width - 56 * 2) * 9 / 16)),
        },

        gui.Panel{
            flow = "horizontal",
            width = width - 56 * 2,
            height = "auto",
            halign = "center",
            tmargin = 48,
            bmargin = 56,
            MakeAboutColumn(leftW),
            gui.Panel{
                width = rightW,
                height = "auto",
                lmargin = gap,
                valign = "top",
                MakeBuyBox(rightW),
            },
        },

        refreshItem = function(element, item)
            local cfg = AdventurePage.Read(item)
            element:SetClass("collapsed", cfg == nil)
            if cfg ~= nil then
                element:FireEventTree("showPage", item, cfg)
            end
        end,
    }
end
