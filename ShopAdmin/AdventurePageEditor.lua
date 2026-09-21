local mod = dmhub.GetModLoading()

--Shop admin editor for an adventure's store page -- item.adventurePage. The
--page itself, and what each part of the config means, is documented at the
--top of Codex Titlescreen/AdventurePage.lua. This editor sits in the item
--editor for Module items (under Module ID) and saves itself a moment after
--the last change, like the dice banner editor.

AdventurePageEditor = {}

local g_maxArt = 3
local g_maxCast = 5
local g_saveDelay = 0.5
local g_extensions = {"jpeg", "jpg", "png", "webp"}

local function NewConfig()
    return {
        heroImage = "",
        tagline = "",
        tags = {},
        publisher = "MCDM",
        aboutTitle = "",
        about = "",
        media = {book = {cover = "", pages = {}}, maps = {}, art = {}},
        cast = {},
    }
end

--Fills in any missing parts, so the editor can index freely whatever shape a
--saved config comes back in.
local function Normalize(cfg)
    cfg.tags = cfg.tags or {}
    cfg.media = cfg.media or {}
    cfg.media.book = cfg.media.book or {}
    cfg.media.book.cover = cfg.media.book.cover or ""
    cfg.media.book.pages = cfg.media.book.pages or {}
    cfg.media.maps = cfg.media.maps or {}
    for _, map in ipairs(cfg.media.maps) do
        map.pins = map.pins or {}
    end
    cfg.media.art = cfg.media.art or {}
    cfg.cast = cfg.cast or {}
    return cfg
end

local function ReadConfig(item)
    local cfg = nil
    pcall(function() cfg = item.adventurePage end)
    if type(cfg) ~= "table" then
        return nil
    end
    return Normalize(cfg)
end

--Opens a file picker and uploads each chosen image to the Core asset store
--(the shop catalog is global, so its art must be too), calling done(guid)
--once per image as it finishes.
local function PickImages(args)
    dmhub.OpenFileDialog{
        id = args.id,
        extensions = g_extensions,
        multiFiles = args.multi == true,
        prompt = args.prompt,
        open = function(path)
            assets:UploadImageAsset{
                core = true,
                path = path,
                description = string.format("AdventurePage: %s", args.itemid),
                error = function(msg)
                    printf("AdventurePageEditor: upload failed: %s", tostring(msg))
                end,
                upload = function(guid)
                    if mod.unloaded then
                        return
                    end
                    args.done(guid)
                end,
            }
        end,
    }
end

--Shows imageid on a thumbnail panel cropped to fill w x h without stretching.
local function SetThumb(panel, imageid, w, h)
    if imageid == nil or imageid == "" then
        panel.bgimage = "panels/square.png"
        panel.selfStyle.bgcolor = "#2b2d31ff"
        panel.selfStyle.imageRect = {x1 = 0, y1 = 0, x2 = 1, y2 = 1}
        return
    end
    panel.bgimage = imageid
    panel.selfStyle.bgcolor = "#2b2d31ff"
    AdventurePage.ImageDimensions(imageid, function(dims)
        if mod.unloaded or not panel.valid or panel.bgimage ~= imageid then
            return
        end
        if dims == nil or (dims.width or 0) <= 0 or (dims.height or 0) <= 0 then
            return
        end
        local boxAspect = w / h
        local imageAspect = dims.width / dims.height
        if imageAspect > boxAspect then
            local f = boxAspect / imageAspect
            panel.selfStyle.imageRect = {x1 = (1 - f) * 0.5, x2 = (1 + f) * 0.5, y1 = 0, y2 = 1}
        else
            local f = imageAspect / boxAspect
            panel.selfStyle.imageRect = {x1 = 0, x2 = 1, y1 = (1 - f) * 0.5, y2 = (1 + f) * 0.5}
        end
        panel.selfStyle.bgcolor = "#ffffffff"
    end)
end

local function Thumb(w, h, extra)
    local args = {
        width = w,
        height = h,
        bgimage = "panels/square.png",
        bgcolor = "#2b2d31ff",
        borderWidth = 1,
        borderColor = "#55575dff",
        cornerRadius = 4,
    }
    for k, v in pairs(extra or {}) do
        args[k] = v
    end
    return gui.Panel(args)
end

local function SmallButton(text, width, click)
    return gui.Button{
        classes = {"sizeS"},
        width = width,
        text = text,
        hmargin = 4,
        click = click,
    }
end

--A small red cross in a thumbnail's top-right corner.
local function RemoveCross(click)
    return gui.Label{
        floating = true,
        halign = "right",
        valign = "top",
        width = 20,
        height = 20,
        text = "X",
        fontSize = 12,
        textAlignment = "center",
        color = "#ffffffff",
        bgimage = "panels/square.png",
        bgcolor = "#a03a2aee",
        cornerRadius = 10,
        hmargin = 2,
        vmargin = 2,
        click = click,
    }
end

local function Hint(text)
    return gui.Label{
        text = text,
        fontSize = 13,
        color = "#9c978eff",
        width = "auto",
        height = "auto",
        halign = "left",
        vmargin = 2,
    }
end

--Collapsible sub-section with a title, open by default.
local function Section(title, hint, children)
    local m_open = true
    local content = gui.Panel{
        flow = "vertical",
        width = "auto",
        height = "auto",
        halign = "left",
        lmargin = 24,
        children = children,
    }
    local arrow = gui.ExpandoArrow{
        classes = {"expanded"},
        interactable = false,
        halign = "left",
        valign = "center",
    }
    return gui.Panel{
        flow = "vertical",
        width = "auto",
        height = "auto",
        halign = "left",
        vmargin = 4,
        gui.Panel{
            flow = "horizontal",
            width = "auto",
            height = 30,
            halign = "left",
            bgimage = "panels/square.png",
            bgcolor = "clear",
            click = function(element)
                m_open = not m_open
                content:SetClass("collapsed", not m_open)
                arrow:SetClass("expanded", m_open)
            end,
            arrow,
            gui.Label{
                text = title,
                fontSize = 20,
                fontWeight = "bold",
                width = "auto",
                height = "auto",
                halign = "left",
                valign = "center",
                hmargin = 8,
                interactable = false,
            },
            gui.Label{
                text = hint or "",
                fontSize = 13,
                color = "#9c978eff",
                width = "auto",
                height = "auto",
                valign = "center",
                interactable = false,
            },
        },
        content,
    }
end

--Builds the editor. It listens for the admin's `item` event (fired down the
--item editor whenever an item is selected or changed).
function AdventurePageEditor.Create()
    local m_item = nil
    local m_cfg = nil
    local m_selectedMap = 1

    local root

    --Coalesce edits into one upload shortly after the last change.
    local m_saveScheduled = false
    local function Save()
        if m_saveScheduled then
            return
        end
        m_saveScheduled = true
        dmhub.Schedule(g_saveDelay, function()
            m_saveScheduled = false
            if mod.unloaded or m_item == nil then
                return
            end
            local ok = pcall(function() m_item.adventurePage = m_cfg end)
            if not ok then
                printf("AdventurePageEditor: this build has no adventurePage field; the page was not saved (rebuild + restart required).")
                return
            end
            m_item:Upload()
        end)
    end

    --Re-sync every control from the working config.
    local function Refresh()
        root:FireEventTree("refreshPage", m_cfg)
    end

    --Change the config, save, and re-sync the editor.
    local function Edit(f)
        if m_cfg == nil then
            return
        end
        f(m_cfg)
        Save()
        Refresh()
    end

    ----------------------------------------------------------------------
    --Generic controls bound to the working config.
    ----------------------------------------------------------------------
    local function TextField(label, get, set, opts)
        opts = opts or {}
        return gui.Panel{
            classes = {"formPanel"},
            gui.Label{
                classes = {"formLabel"},
                text = label,
                valign = "top",
            },
            gui.Input{
                classes = {"formInput"},
                width = opts.width or 460,
                height = opts.height,
                multiline = opts.multiline,
                characterLimit = opts.limit or 200,
                placeholderText = opts.placeholder,
                refreshPage = function(element, cfg)
                    if cfg ~= nil then
                        element.text = get(cfg) or ""
                    end
                end,
                change = function(element)
                    if m_cfg == nil then
                        return
                    end
                    set(m_cfg, element.text)
                    Save()
                end,
            },
        }
    end

    --An image slot: thumbnail plus Upload / Clear.
    local function ImageSlot(w, h, uploadId, prompt, get, set)
        local thumb = Thumb(w, h, {
            refreshPage = function(element, cfg)
                if cfg ~= nil then
                    SetThumb(element, get(cfg), w, h)
                end
            end,
        })
        return gui.Panel{
            flow = "vertical",
            width = "auto",
            height = "auto",
            halign = "left",
            valign = "top",
            rmargin = 16,
            thumb,
            gui.Panel{
                flow = "horizontal",
                width = "auto",
                height = "auto",
                vmargin = 4,
                SmallButton("Upload...", 100, function()
                    if m_cfg == nil then
                        return
                    end
                    PickImages{id = uploadId, prompt = prompt, itemid = m_item.id, done = function(guid)
                        Edit(function(cfg) set(cfg, guid) end)
                    end}
                end),
                SmallButton("Clear", 70, function()
                    Edit(function(cfg) set(cfg, "") end)
                end),
            },
        }
    end

    ----------------------------------------------------------------------
    --Hero
    ----------------------------------------------------------------------
    local heroSection = Section("Hero", "key art, pitch and tags over the top of the page", {
        gui.Panel{
            flow = "horizontal",
            width = "auto",
            height = "auto",
            halign = "left",
            ImageSlot(240, 104, "AdventureHero", "Choose the key art (wide, no text on it)",
                function(cfg) return cfg.heroImage end,
                function(cfg, v) cfg.heroImage = v end),
            gui.Panel{
                flow = "vertical",
                width = "auto",
                height = "auto",
                valign = "top",
                TextField("Tagline:", function(cfg) return cfg.tagline end,
                    function(cfg, v) cfg.tagline = v end, {placeholder = "One line pitch"}),
                TextField("Tags:", function(cfg) return table.concat(cfg.tags or {}, ", ") end,
                    function(cfg, v)
                        local tags = {}
                        for tag in string.gmatch(v, "[^,]+") do
                            tag = tag:match("^%s*(.-)%s*$")
                            if tag ~= "" then
                                tags[#tags + 1] = tag
                            end
                        end
                        cfg.tags = tags
                    end, {placeholder = "Levels 1-3, 4-6 heroes, About 3 sessions"}),
                TextField("Publisher:", function(cfg) return cfg.publisher end,
                    function(cfg, v) cfg.publisher = v end, {width = 200}),
            },
        },
        Hint("Without key art, the page uses the widest image in the item's gallery."),
    })

    ----------------------------------------------------------------------
    --About
    ----------------------------------------------------------------------
    local aboutSection = Section("About", "heading and description", {
        TextField("Heading:", function(cfg) return cfg.aboutTitle end,
            function(cfg, v) cfg.aboutTitle = v end, {placeholder = "About this adventure"}),
        TextField("Description:", function(cfg) return cfg.about end,
            function(cfg, v) cfg.about = v end,
            {multiline = true, height = 110, limit = 4000, placeholder = "Leave empty to use the item's details text"}),
    })

    ----------------------------------------------------------------------
    --The book: cover + pages
    ----------------------------------------------------------------------
    local pageW, pageH = 68, 90
    local pagesStrip = gui.Panel{
        flow = "horizontal",
        wrap = true,
        width = 900,
        height = "auto",
        halign = "left",
        valign = "top",
        refreshPage = function(element, cfg)
            if cfg == nil then
                return
            end
            local children = {}
            for i, imageid in ipairs(cfg.media.book.pages) do
                local thumb = Thumb(pageW, pageH, {rmargin = 8, bmargin = 8})
                SetThumb(thumb, imageid, pageW, pageH)
                thumb.children = {RemoveCross(function()
                    Edit(function(c) table.remove(c.media.book.pages, i) end)
                end)}
                children[#children + 1] = thumb
            end
            children[#children + 1] = Thumb(pageW, pageH, {
                borderColor = "#77736cff",
                bgcolor = "#ffffff08",
                gui.Label{
                    text = "+ Add\npages",
                    fontSize = 12,
                    color = "#cfc9bdff",
                    width = "auto",
                    height = "auto",
                    halign = "center",
                    valign = "center",
                    textAlignment = "center",
                    interactable = false,
                },
                click = function()
                    if m_cfg == nil then
                        return
                    end
                    PickImages{id = "AdventurePages", multi = true, prompt = "Choose sample pages", itemid = m_item.id,
                        done = function(guid)
                            Edit(function(c) table.insert(c.media.book.pages, guid) end)
                        end}
                end,
            })
            element.children = children
        end,
    }

    local bookSection = Section("The book", "the cover, with pages fanned out behind it", {
        gui.Panel{
            flow = "horizontal",
            width = "auto",
            height = "auto",
            halign = "left",
            ImageSlot(90, 120, "AdventureCover", "Choose the book cover",
                function(cfg) return cfg.media.book.cover end,
                function(cfg, v) cfg.media.book.cover = v end),
            pagesStrip,
        },
        Hint("Pages alternate left and right of the cover; the first two sit closest to it."),
    })

    ----------------------------------------------------------------------
    --Maps: list, a big preview to click place names onto, and their names.
    ----------------------------------------------------------------------
    local mapListW, mapListH = 128, 72
    local previewMaxW, previewMaxH = 520, 320

    local mapList = gui.Panel{
        flow = "vertical",
        width = "auto",
        height = "auto",
        valign = "top",
        rmargin = 16,
        refreshPage = function(element, cfg)
            if cfg == nil then
                return
            end
            local children = {}
            for i, map in ipairs(cfg.media.maps) do
                local thumb = Thumb(mapListW, mapListH, {
                    bmargin = 8,
                    borderWidth = cond(i == m_selectedMap, 2, 1),
                    borderColor = cond(i == m_selectedMap, "#f6ddb6ff", "#55575dff"),
                    click = function()
                        m_selectedMap = i
                        Refresh()
                    end,
                })
                SetThumb(thumb, map.image, mapListW, mapListH)
                children[#children + 1] = thumb
            end
            children[#children + 1] = Thumb(mapListW, mapListH, {
                borderColor = "#77736cff",
                bgcolor = "#ffffff08",
                gui.Label{
                    text = "+ Add maps",
                    fontSize = 12,
                    color = "#cfc9bdff",
                    width = "auto",
                    height = "auto",
                    halign = "center",
                    valign = "center",
                    interactable = false,
                },
                click = function()
                    if m_cfg == nil then
                        return
                    end
                    PickImages{id = "AdventureMaps", multi = true, prompt = "Choose battle maps", itemid = m_item.id,
                        done = function(guid)
                            Edit(function(c)
                                table.insert(c.media.maps, {image = guid, name = "", pins = {}})
                                m_selectedMap = #c.media.maps
                            end)
                        end}
                end,
            })
            element.children = children
        end,
    }

    --The selected map, shown whole at its own aspect. Clicking drops a new
    --place name at that spot; each pin is a dot with its name beside it.
    local mapPreview
    mapPreview = gui.Panel{
        flow = "none",
        width = previewMaxW,
        height = previewMaxH,
        valign = "top",
        bgimage = "panels/square.png",
        bgcolor = "#2b2d31ff",
        data = {w = previewMaxW, h = previewMaxH},

        click = function(element)
            local map = m_cfg ~= nil and m_cfg.media.maps[m_selectedMap] or nil
            local point = element.mousePoint
            if map == nil or point == nil then
                return
            end
            --mousePoint is 0..1 with y running bottom-up; pins are top-down.
            Edit(function()
                table.insert(map.pins, {label = "New place", x = point.x, y = 1 - point.y})
            end)
        end,

        refreshPage = function(element, cfg)
            local map = cfg ~= nil and cfg.media.maps[m_selectedMap] or nil
            if map == nil then
                element.bgimage = "panels/square.png"
                element.selfStyle.bgcolor = "#2b2d31ff"
                element.children = {Hint("Add a map, then click on it to place names.")}
                return
            end

            local function Layout(w, h)
                element.data.w = w
                element.data.h = h
                element.selfStyle.width = w
                element.selfStyle.height = h
                local children = {}
                for _, pin in ipairs(map.pins) do
                    children[#children + 1] = gui.Panel{
                        floating = true,
                        flow = "horizontal",
                        width = "auto",
                        height = "auto",
                        halign = "left",
                        valign = "top",
                        x = (pin.x or 0.5) * w - 5,
                        y = (pin.y or 0.5) * h - 5,
                        interactable = false,
                        gui.Panel{
                            width = 10,
                            height = 10,
                            bgimage = "panels/square.png",
                            bgcolor = "#f6ddb6ff",
                            cornerRadius = 5,
                            borderWidth = 1,
                            borderColor = "#000000ff",
                        },
                        gui.Label{
                            text = pin.label or "",
                            fontSize = 12,
                            color = "#f3ecdfff",
                            width = "auto",
                            height = "auto",
                            lmargin = 4,
                            hpad = 5,
                            vpad = 1,
                            borderBox = true,
                            bgimage = "panels/square.png",
                            bgcolor = "#000000c0",
                            cornerRadius = 3,
                        },
                    }
                end
                element.children = children
            end

            element.bgimage = map.image
            element.selfStyle.imageRect = {x1 = 0, y1 = 0, x2 = 1, y2 = 1}
            local imageid = map.image
            AdventurePage.ImageDimensions(imageid, function(dims)
                if mod.unloaded or not element.valid or element.bgimage ~= imageid then
                    return
                end
                if dims == nil or (dims.width or 0) <= 0 or (dims.height or 0) <= 0 then
                    return
                end
                --fit the whole map inside the preview box at its own aspect.
                local scale = math.min(previewMaxW / dims.width, previewMaxH / dims.height)
                element.selfStyle.bgcolor = "#ffffffff"
                Layout(math.floor(dims.width * scale), math.floor(dims.height * scale))
            end)
        end,
    }

    local mapDetails = gui.Panel{
        flow = "vertical",
        width = "auto",
        height = "auto",
        valign = "top",
        lmargin = 16,
        refreshPage = function(element, cfg)
            local map = cfg ~= nil and cfg.media.maps[m_selectedMap] or nil
            element:SetClass("collapsed", map == nil)
            if map == nil then
                return
            end

            local rows = {
                gui.Panel{
                    classes = {"formPanel"},
                    gui.Label{classes = {"formLabel"}, text = "Map name:", valign = "top"},
                    gui.Input{
                        classes = {"formInput"},
                        width = 240,
                        characterLimit = 80,
                        text = map.name or "",
                        placeholderText = "Shown under the map",
                        change = function(input)
                            map.name = input.text
                            Save()
                        end,
                    },
                },
                Hint(cond(#map.pins == 0, "Click on the map to place a name.", "Places:")),
            }
            for i, pin in ipairs(map.pins) do
                rows[#rows + 1] = gui.Panel{
                    flow = "horizontal",
                    width = "auto",
                    height = "auto",
                    halign = "left",
                    vmargin = 2,
                    gui.Input{
                        classes = {"formInput"},
                        width = 220,
                        characterLimit = 60,
                        text = pin.label or "",
                        change = function(input)
                            pin.label = input.text
                            Save()
                            mapPreview:FireEvent("refreshPage", m_cfg)
                        end,
                    },
                    SmallButton("Remove", 80, function()
                        Edit(function() table.remove(map.pins, i) end)
                    end),
                }
            end
            rows[#rows + 1] = gui.Panel{
                width = "auto",
                height = "auto",
                halign = "left",
                tmargin = 12,
                SmallButton("Remove map", 120, function()
                    Edit(function(c)
                        table.remove(c.media.maps, m_selectedMap)
                        m_selectedMap = math.max(1, math.min(m_selectedMap, #c.media.maps))
                    end)
                end),
            }
            element.children = rows
        end,
    }

    local mapsSection = Section("Maps", "shown in turn, panning slowly, with place names fading in", {
        gui.Panel{
            flow = "horizontal",
            width = "auto",
            height = "auto",
            halign = "left",
            mapList,
            mapPreview,
            mapDetails,
        },
    })

    ----------------------------------------------------------------------
    --Art and cast: short lists of image + text rows.
    ----------------------------------------------------------------------
    local function ListEditor(args)
        return gui.Panel{
            flow = "vertical",
            width = "auto",
            height = "auto",
            halign = "left",
            refreshPage = function(element, cfg)
                if cfg == nil then
                    return
                end
                local list = args.list(cfg)
                local rows = {}
                for i, entry in ipairs(list) do
                    local thumb = Thumb(args.w, args.h, {valign = "top", rmargin = 12})
                    SetThumb(thumb, entry.image, args.w, args.h)
                    local fields = {}
                    for _, field in ipairs(args.fields) do
                        fields[#fields + 1] = gui.Panel{
                            classes = {"formPanel"},
                            gui.Label{classes = {"formLabel"}, text = field.label, valign = "top"},
                            gui.Input{
                                classes = {"formInput"},
                                width = 300,
                                characterLimit = 80,
                                text = entry[field.key] or "",
                                placeholderText = field.placeholder,
                                change = function(input)
                                    entry[field.key] = input.text
                                    Save()
                                end,
                            },
                        }
                    end
                    fields[#fields + 1] = gui.Panel{
                        flow = "horizontal",
                        width = "auto",
                        height = "auto",
                        halign = "left",
                        SmallButton("Replace image...", 140, function()
                            PickImages{id = args.uploadId, prompt = args.prompt, itemid = m_item.id, done = function(guid)
                                Edit(function() entry.image = guid end)
                            end}
                        end),
                        SmallButton("Remove", 80, function()
                            Edit(function(c) table.remove(args.list(c), i) end)
                        end),
                    }
                    rows[#rows + 1] = gui.Panel{
                        flow = "horizontal",
                        width = "auto",
                        height = "auto",
                        halign = "left",
                        vmargin = 6,
                        thumb,
                        gui.Panel{flow = "vertical", width = "auto", height = "auto", valign = "top", children = fields},
                    }
                end
                if #list < args.max then
                    rows[#rows + 1] = gui.Panel{
                        width = "auto",
                        height = "auto",
                        halign = "left",
                        vmargin = 4,
                        SmallButton(args.addText, 180, function()
                            if m_cfg == nil then
                                return
                            end
                            PickImages{id = args.uploadId, prompt = args.prompt, itemid = m_item.id, done = function(guid)
                                Edit(function(c)
                                    local l = args.list(c)
                                    if #l < args.max then
                                        local entry = {image = guid}
                                        for _, field in ipairs(args.fields) do
                                            entry[field.key] = ""
                                        end
                                        table.insert(l, entry)
                                    end
                                end)
                            end}
                        end),
                    }
                end
                element.children = rows
            end,
        }
    end

    local artSection = Section("Art", string.format("up to %d pieces, each shown whole", g_maxArt), {
        ListEditor{
            list = function(cfg) return cfg.media.art end,
            max = g_maxArt,
            w = 160,
            h = 90,
            uploadId = "AdventureArt",
            prompt = "Choose art",
            addText = "+ Add art...",
            fields = {
                {key = "caption", label = "Caption:", placeholder = "Shown under the art"},
                {key = "label", label = "Tab label:", placeholder = "Art"},
            },
        },
    })

    local castSection = Section("Cast", string.format("up to %d, shown as round portraits", g_maxCast), {
        ListEditor{
            list = function(cfg) return cfg.cast end,
            max = g_maxCast,
            w = 90,
            h = 90,
            uploadId = "AdventureCast",
            prompt = "Choose a portrait",
            addText = "+ Add cast member...",
            fields = {
                {key = "name", label = "Name:", placeholder = "Captain Moon"},
                {key = "role", label = "Role:", placeholder = "Ally, Villain, Monster..."},
            },
        },
    })

    ----------------------------------------------------------------------
    --Preview: the real store page, in a modal.
    ----------------------------------------------------------------------
    local function ShowPreview()
        if m_item == nil or m_cfg == nil or ShowShopItemDetails == nil then
            return
        end
        --the page reads item.adventurePage, so push the working config first.
        pcall(function() m_item.adventurePage = m_cfg end)
        local item = m_item
        local details = ShowShopItemDetails{halign = "center", valign = "top"}
        details:FireEventTree("showProductDetails", item)
        details:FireEventTree("refreshItem", item)
        details:FireEventTree("refreshCart", {})
        gui.ShowModal(gui.Panel{
            flow = "vertical",
            width = 1240,
            height = 1000,
            halign = "center",
            valign = "center",
            bgimage = "panels/square.png",
            bgcolor = "#111113ff",
            borderWidth = 1,
            borderColor = "#f6ddb680",
            cornerRadius = 8,
            gui.Panel{
                flow = "horizontal",
                width = "100%",
                height = 44,
                gui.Label{
                    text = "Store page preview",
                    fontSize = 16,
                    width = "auto",
                    height = "auto",
                    halign = "left",
                    valign = "center",
                    hmargin = 16,
                },
                gui.Button{
                    classes = {"sizeS"},
                    text = "Close",
                    width = 90,
                    halign = "right",
                    valign = "center",
                    hmargin = 12,
                    click = function()
                        gui.CloseModal()
                    end,
                },
            },
            gui.Panel{
                width = 1200,
                height = 940,
                halign = "center",
                vscroll = true,
                details,
            },
        })
    end

    ----------------------------------------------------------------------

    local body = gui.Panel{
        flow = "vertical",
        width = "auto",
        height = "auto",
        halign = "left",
        heroSection,
        aboutSection,
        bookSection,
        mapsSection,
        artSection,
        castSection,
    }

    local enableCheck = gui.Check{
        text = "Use adventure page",
        tooltip = "Give this adventure the full store page. Turning it off deletes the page settings and the item goes back to the plain details layout.",
        change = function(element)
            if m_item == nil then
                return
            end
            if element.value then
                m_cfg = ReadConfig(m_item) or NewConfig()
                Save()
                Refresh()
                return
            end

            --Turning the page off deletes everything set up for it, so keep
            --the box ticked until that is confirmed.
            element.value = true
            DTConfirmationDialog.ShowModal(
                "Turn off the adventure page?",
                "This deletes all of this item's adventure page settings (art, maps, places, cast). The images stay in the asset store.",
                "Delete page",
                "Cancel",
                function()
                    m_cfg = nil
                    Save()
                    Refresh()
                end,
                function() end)
        end,
    }

    local previewButton = gui.Button{
        classes = {"sizeS"},
        text = "Preview page",
        width = 140,
        hmargin = 16,
        click = function()
            ShowPreview()
        end,
    }

    --Drafts the whole page from the module (see AdventurePage.AutoFill),
    --replacing what is there after a confirmation. Takes a few seconds while
    --the module's images are looked up.
    local fillButton
    fillButton = gui.Button{
        classes = {"sizeS"},
        text = "Fill from adventure",
        width = 170,
        click = function()
            if m_item == nil then
                return
            end
            local item = m_item
            local function Run()
                fillButton.text = "Filling..."
                AdventurePage.AutoFill(item, function(cfg, err)
                    if mod.unloaded or not fillButton.valid then
                        return
                    end
                    fillButton.text = "Fill from adventure"
                    if cfg == nil then
                        printf("AdventurePageEditor: %s", tostring(err))
                        return
                    end
                    if m_item ~= item then
                        return
                    end
                    m_cfg = Normalize(cfg)
                    m_selectedMap = 1
                    Save()
                    Refresh()
                end)
            end
            if m_cfg == nil then
                Run()
                return
            end
            DTConfirmationDialog.ShowModal(
                "Replace the adventure page?",
                "This replaces everything on the page with a fresh draft built from the module.",
                "Replace",
                "Cancel",
                Run,
                function() end)
        end,
    }

    root = gui.Panel{
        flow = "vertical",
        width = "auto",
        height = "auto",
        halign = "left",
        vmargin = 8,

        gui.Panel{
            flow = "horizontal",
            width = "auto",
            height = "auto",
            halign = "left",
            gui.Label{
                text = "Adventure page",
                fontSize = 24,
                fontWeight = "bold",
                width = "auto",
                height = "auto",
                valign = "center",
                rmargin = 24,
            },
            enableCheck,
            previewButton,
            fillButton,
        },
        body,

        refreshPage = function(element, cfg)
            enableCheck.value = cfg ~= nil
            body:SetClass("collapsed", cfg == nil)
            previewButton:SetClass("collapsed", cfg == nil)
        end,

        item = function(element, item)
            local changed = m_item ~= item
            m_item = item
            element:SetClass("collapsed", item == nil or item.itemType ~= "Module")
            if item == nil or item.itemType ~= "Module" then
                return
            end
            --The admin fires `item` after every edit to the item (price, type,
            --...). Only re-read the saved page when a different item is picked:
            --re-reading on the same item would drop an edit still waiting in
            --the save delay.
            if changed then
                m_selectedMap = 1
                m_cfg = ReadConfig(item)
            end
            Refresh()
        end,
    }

    return root
end
