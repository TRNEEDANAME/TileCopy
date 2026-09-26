--[[
    TileCopy_Core.lua  (shared)

    The actual "copy" and "paste" logic, kept separate from any UI so it can
    be called from the client (single player / previewing) and from the
    server
--]]

require "TileCopy_Util"
require "Moveables/ISMoveableSpriteProps"

TileCopy = TileCopy or {}
TileCopy.Core = TileCopy.Core or {}
local Core = TileCopy.Core
local Util = TileCopy.Util

local function propsHasFlag(props, flag)
    local key = (IsoFlagType and IsoFlagType[flag]) or flag
    if props.has and props:has(key) then return true end
    if props.Is and props:Is(key) then return true end
    return false
end

local function hasPropertyFlag(obj, flags)
    if not obj or not obj.getProperties then return false end
    local props = obj:getProperties()
    if not props then return false end

    for _, flag in ipairs(flags) do
        if propsHasFlag(props, flag) then return true end
    end
    return false
end
local WALL_FLAGS = {
    "WallN", "WallW", "WallNW", "WallSE", "WallNTrans", "WallWTrans",
    "doorN", "doorW", "DoorWallN", "DoorWallW",
    "windowN", "windowW", "WindowN", "WindowW",
}
local STRUCTURAL_FLAGS = { "solid", "solidtrans", "collideN", "collideW", "HoppableN", "HoppableW" }

local function isSpecialObject(obj)
    local s = tostring(obj)
    if not s then return false end
    return s:match("^zombie%.iso%.IsoObject@") == nil
end

local function isInstance(obj, className)
    if not instanceof then return false end
    return instanceof(obj, className)
end

local WALL_TYPES = { "wall", "doorFrN", "doorFrW" }

local function hasWallType(obj)
    if not IsoObjectType then return false end
    local objType = obj.getType and obj:getType()
    local spriteType = nil
    local sprite = obj.getSprite and obj:getSprite()
    if sprite and sprite.getType then spriteType = sprite:getType() end
    for _, name in ipairs(WALL_TYPES) do
        local t = IsoObjectType[name]
        if t and (objType == t or spriteType == t) then return true end
    end
    return false
end

local function isWallObject(obj)
    if isInstance(obj, "IsoDoor") or isInstance(obj, "IsoWindow") or isInstance(obj, "IsoWindowFrame") then
        return true
    end
    return hasPropertyFlag(obj, WALL_FLAGS) or hasWallType(obj)
end

local function hasContainer(obj)
    if not (obj and obj.getContainer) then return false end
    return obj:getContainer() ~= nil
end

local function isWallHanging(obj)
    local props = obj.getProperties and obj:getProperties()
    if not (props and props.get) then return false end
    return props:get("MoveType") == "WallObject"
end

local function isStructuralObject(obj)
    return hasContainer(obj)
        or isWallHanging(obj)
        or hasPropertyFlag(obj, STRUCTURAL_FLAGS)
        or isInstance(obj, "IsoThumpable")
        or isSpecialObject(obj)
end

function Core.classifyObject(obj)
    if isInstance(obj, "IsoWorldInventoryObject") or isInstance(obj, "IsoMovingObject") then
        return "skip"
    end
    if isWallObject(obj) then return "wall" end
    if isStructuralObject(obj) then return "structural" end
    return "overlay"
end

local function getSpriteNameSafe(obj)
    if obj and obj.getSpriteName then
        local name = obj:getSpriteName()
        if name then return name end
    end
    if obj and obj.getSprite then
        local sprite = obj:getSprite()
        if sprite and sprite.getName then
            return sprite:getName()
        end
    end
    return nil
end

--- Captures the contents of every container on an object (a fridge has a
--- fridge + freezer, for example). Returns a list, or nil if there are none.
function Core.captureContainers(obj)
    local count = obj.getContainerCount and obj:getContainerCount()
    if not count or count == 0 then
        local single = Core.captureContainer(obj)
        return single and { single } or nil
    end
    local list = {}
    for i = 0, count - 1 do
        local container = obj:getContainerByIndex(i)
        if container then
            list[#list + 1] = Core.captureContainer(obj, container)
        end
    end
    return #list > 0 and list or nil
end

--- Captures the contents (items) of one container (defaults to the
--- object's main container).
function Core.captureContainer(obj, container)
    if not container then
        if not obj.getContainer then return nil end
        container = obj:getContainer()
        if not container then return nil end
    end

    local items = {}
    local itemList = container:getItems()
    if itemList then
        for i = 0, itemList:size() - 1 do
            local item = itemList:get(i)
            local entry = {}
            entry.fullType = item:getFullType()

            if item.getCount then entry.count = item:getCount() end
            if item.getCondition then entry.condition = item:getCondition() end
            if item.getCurrentUsesFloat then entry.uses = item:getCurrentUsesFloat() end

            if entry.fullType then
                items[#items + 1] = entry
            end
        end
    end

    local containerType = container:getType()
    local capacity = container:getCapacity()

    return {
        containerType = containerType,
        capacity = capacity,
        items = items,
    }
end

local function captureAttached(obj, includeMoveable, includeDecals)
    local list = obj.getAttachedAnimSprite and obj:getAttachedAnimSprite()
    if not list then return nil end
    local out = {}
    for i = 0, list:size() - 1 do
        local inst = list:get(i)
        local spr = inst and inst.getParentSprite and inst:getParentSprite()
        local name = spr and spr:getName()
        if name then
            local props = spr:getProperties()
            local moveable = props and propsHasFlag(props, "IsMoveAble")
            if (moveable and includeMoveable) or (not moveable and includeDecals) then
                out[#out + 1] = name
            end
        end
    end
    if #out == 0 then return nil end
    return out
end

--- Captures a rectangular region into a data table.
-- @param x1,y1,x2,y2 any two opposite corners (order doesn't matter)
-- @param z            floor/z-level to copy
-- @param opts         { includeTiles=bool, includeContainers=bool, includeOverlay=bool }
function Core.captureArea(x1, y1, x2, y2, z, opts)
    opts = opts or {}
    local includeTiles = opts.includeTiles ~= false
    local includeWalls = opts.includeWalls ~= false
    local includeGround = opts.includeGround ~= false
    local includeContainers = opts.includeContainers ~= false
    local includeOverlay = opts.includeOverlay ~= false

    local minX, maxX = math.min(x1, x2), math.max(x1, x2)
    local minY, maxY = math.min(y1, y2), math.max(y1, y2)

    local cell = getCell()
    local data = {
        width = maxX - minX + 1,
        height = maxY - minY + 1,
        includeTiles = includeTiles,
        includeWalls = includeWalls,
        includeGround = includeGround,
        includeContainers = includeContainers,
        includeOverlay = includeOverlay,
        squares = {},
    }

    for y = minY, maxY do
        for x = minX, maxX do
            local sq = cell and cell:getGridSquare(x, y, z)
            local entry = { dx = x - minX, dy = y - minY }

            if sq then
                if includeGround then
                    local floorObj = sq:getFloor()
                    if floorObj then
                        entry.floor = getSpriteNameSafe(floorObj)
                    end
                end

                local structObjects, overlayObjects = {}, {}
                local objs = sq:getObjects()
                if objs then
                    local floorRef = sq:getFloor()
                    for i = 0, objs:size() - 1 do
                        local obj = objs:get(i)
                        if obj ~= floorRef then
                            local spriteName = getSpriteNameSafe(obj)
                            -- An open door's current sprite is the "open"
                            -- frame, which doesn't carry the door flags, so
                            -- it wouldn't be rebuilt as a door. Save the
                            -- closed sprite instead.
                            if obj.IsOpen and obj.getClosedSprite and obj:IsOpen() then
                                local closed = obj:getClosedSprite()
                                if closed and closed:getName() then spriteName = closed:getName() end
                            end
                            if spriteName then
                                local class = Core.classifyObject(obj)
                                Util.log("sq", x, y, "obj", spriteName, "class=", class)

                                if class == "skip" then
                                    -- dropped items etc. - not part of the build
                                elseif class == "wall" then
                                    if includeWalls then
                                        structObjects[#structObjects + 1] = {
                                            sprite = spriteName, layer = "wall",
                                            attached = captureAttached(obj, includeTiles, includeOverlay),
                                        }
                                    end
                                elseif class == "structural" then
                                    if includeTiles then
                                        local rec = {
                                            sprite = spriteName, layer = "structural",
                                            attached = captureAttached(obj, includeTiles, includeOverlay),
                                        }
                                        if includeContainers then
                                            rec.containers = Core.captureContainers(obj)
                                        end
                                        structObjects[#structObjects + 1] = rec
                                    end
                                else -- overlay
                                    if includeOverlay then
                                        overlayObjects[#overlayObjects + 1] = { sprite = spriteName }
                                    end
                                end
                            end
                        end
                    end
                end

                if includeTiles or includeWalls then entry.objects = structObjects end
                if includeOverlay then entry.overlay = overlayObjects end
            end

            data.squares[#data.squares + 1] = entry
        end
    end

    Util.info("copy: captured", data.width, "x", data.height, "at", minX, minY, z,
        "- tiles/walls/ground/containers/overlay =",
        includeTiles, includeWalls, includeGround, includeContainers, includeOverlay)
    return data
end

-- Shareable strings -------------------------------------------------------
-- For sharing with another person we additionally base64-wrap it so the
-- result is one line of plain A-Z/a-z/0-9/+//= text with no quotes or
-- newlines to mangle when pasted into chat, a forum post, a text file, etc.
local STRING_FORMAT_TAG = "TCS1" -- TileCopy String

--- Turns a captured area (as returned by Core.captureArea, or any clipboard
--- entry) into a single shareable string.
--- Also decodes the result straight back, so a string that can't be
--- imported is caught at export time instead of by whoever receives it.
--- Returns the string, or nil plus a reason.
local function firstDifference(a, b)
    local n = math.min(#a, #b)
    for i = 1, n do
        if a:sub(i, i) ~= b:sub(i, i) then return i end
    end
    if #a ~= #b then return n + 1 end
    return nil
end

function Core.areaToString(data)
    Util.info("export: start", data and data.name, data and data.width, "x", data and data.height,
        "squares=", data and data.squares and #data.squares)
    if not data then return nil, "nothing selected" end

    local serialized = Util.serialize(data)
    if not serialized then
        Util.info("export: serialize FAILED")
        return nil, "serialize failed"
    end
    Util.info("export: serialized", Util.preview(serialized))

    local encoded = Util.base64Encode(serialized)
    if not encoded then
        Util.info("export: base64 encode FAILED")
        return nil, "encode failed"
    end
    Util.info("export: encoded length", #encoded, "(expected", math.ceil(#serialized / 3) * 4 .. ")")
    local str = STRING_FORMAT_TAG .. ":" .. encoded

    -- Self-check: decode straight back and compare byte for byte.
    local decoded = Util.base64Decode(encoded)
    if not decoded then
        Util.info("export: self-check decode FAILED")
    elseif decoded ~= serialized then
        local at = firstDifference(decoded, serialized)
        Util.info("export: self-check MISMATCH at byte", at, "of", #serialized, "(decoded", #decoded, "bytes)")
        Util.info("export:   original near there:", serialized:sub(math.max(1, (at or 1) - 20), (at or 1) + 20))
        Util.info("export:   decoded  near there:", decoded:sub(math.max(1, (at or 1) - 20), (at or 1) + 20))
    else
        Util.info("export: self-check base64 round trip OK")
    end

    local check, err = Core.areaFromString(str)
    if not check then
        Util.info("export: self-check import FAILED -", err)
        return nil, "self-check failed: " .. tostring(err)
    end
    Util.info("export: done,", #str, "chars")
    return str
end

--- Reverses Core.areaToString. Returns the captured-area table on success,
--- or nil plus reason on failure.
function Core.areaFromString(str)
    Util.info("import: input", Util.preview(str))
    if not str or str == "" then return nil, "that field is empty" end

    -- Find the tag with a plain find (no pattern over the whole string);
    -- anything before it (stray spaces, chat prefixes) is ignored.
    local tagPos = str:find(STRING_FORMAT_TAG .. ":", 1, true)
    if not tagPos then
        Util.info("import: no", STRING_FORMAT_TAG .. ":", "prefix found")
        return nil, "not a Tile Copy string (no " .. STRING_FORMAT_TAG .. ": prefix, got " .. #str .. " chars)"
    end
    local encoded = str:sub(tagPos + #STRING_FORMAT_TAG + 1)
    Util.info("import: prefix at char", tagPos, "- encoded part is", #encoded, "chars",
        "(length mod 4 =", #encoded % 4 .. ", should be 0)")

    local serialized = Util.base64Decode(encoded)
    if not serialized or serialized == "" then
        Util.info("import: base64 decode FAILED")
        return nil, "base64 decode failed (" .. #encoded .. " chars)"
    end
    Util.info("import: decoded", Util.preview(serialized))

    local data, desErr = Util.deserialize(serialized)
    if not data or type(data) ~= "table" or not data.squares then
        Util.info("import: parse FAILED -", desErr, "| got type", type(data),
            "| has squares:", type(data) == "table" and data.squares ~= nil)
        return nil, "could not read it (" .. #encoded .. " chars, truncated?): " .. tostring(desErr)
    end

    Util.info("import: OK -", data.name, data.width, "x", data.height, "squares=", #data.squares)
    return data
end

--- Removes one object from a square. In multiplayer this only ever runs on
--- the server (see TileCopy_ServerCommands)
local function removeSquareObject(square, object)
    if not square or not object then return false end
    if isServer() then
        square:transmitRemoveItemFromSquareOnClients(object)
    end
    square:RemoveTileObject(object)
    return true
end

local function placeSprite(sq, spriteName)
    local sprite = getSprite and getSprite(spriteName)
    if sprite and ISMoveableSpriteProps and ISMoveableSpriteProps.new then
        local props = ISMoveableSpriteProps.new(sprite)
        props.rawWeight = 10
        -- nil result is still a success for tiles that get merged into
        -- something already there (wall overlays, floor tiles).
        local result = props:placeMoveableInternal(sq, instanceItem("Base.Plank"), spriteName)
        return result, true
    end

    local obj = IsoObject.new(sq, spriteName)
    if not obj then return nil, false end
    sq:AddTileObject(obj)
    if isServer() then obj:transmitCompleteItemToClients() end
    return obj, true
end

local function applyAttached(obj, rec)
    if not rec.attached or not obj.AttachExistingAnim then return end
    for _, name in ipairs(rec.attached) do
        local spr = getSprite(name)
        if spr then
            obj:AttachExistingAnim(spr, 0, 0, false, 0, false, 0)
        end
    end
    if isServer() then obj:transmitUpdatedSpriteToClients() end
end

--- Plain decorative sprite (rug, grime) - no behaviour needed.
local function placeOverlay(sq, spriteName)
    local obj = IsoObject.new(sq, spriteName)
    if not obj then return nil end
    sq:AddTileObject(obj)
    if isServer() then obj:transmitCompleteItemToClients() end
    return obj
end

local function fillContainer(container, containerData)
    if not container or not containerData or not containerData.items then return end
    for _, itemData in ipairs(containerData.items) do
        if itemData.fullType then
            local newItem = container:AddItem(itemData.fullType)
            if newItem then
                if itemData.count and newItem.setCount then
                    newItem:setCount(itemData.count)
                end
                if itemData.condition and newItem.setCondition then
                    newItem:setCondition(itemData.condition)
                end
                if itemData.uses and newItem.setCurrentUsesFloat then
                    newItem:setCurrentUsesFloat(itemData.uses)
                end
                if isServer() and sendAddItemToContainer then
                    sendAddItemToContainer(container, newItem)
                end
            end
        end
    end
    container:setExplored(true)
    container:setDrawDirty(true)
end

--- Places the saved items into a freshly placed object's containers.
function Core.applyContainers(obj, rec)
    local list = rec.containers or (rec.container and { rec.container }) or nil
    if not list then return end

    local count = obj.getContainerCount and obj:getContainerCount()
    for i, containerData in ipairs(list) do
        local container
        if count and count >= i then
            container = obj:getContainerByIndex(i - 1)
        elseif i == 1 and obj.getContainer then
            container = obj:getContainer()
        end
        fillContainer(container, containerData)
    end
end

--- Pastes a previously captured data table with its (0,0) corner at
--- destX,destY,destZ.
function Core.applyArea(data, destX, destY, destZ)
    if not data or not data.squares then return false end
    local cell = getCell()
    if not cell then return false end

    local applied = { objects = {} }
    Core.lastApplied = applied

    local touchedSquares = {}

    for _, entry in ipairs(data.squares) do
        local x, y, z = destX + entry.dx, destY + entry.dy, destZ
        local sq = cell:getGridSquare(x, y, z)
        if sq then
            touchedSquares[#touchedSquares + 1] = sq

            if entry.floor then
                local existingFloor = sq:getFloor()
                if existingFloor then
                    local oldSprite = existingFloor:getSpriteName()
                    local newSprite = getSprite(entry.floor)
                    if newSprite and oldSprite ~= entry.floor then
                        existingFloor:setSprite(newSprite)
                        if isServer() then
                            existingFloor:transmitUpdatedSpriteToClients()
                        end
                        applied.objects[#applied.objects + 1] = {
                            square = sq, floor = existingFloor, oldSprite = oldSprite,
                        }
                    end
                else
                    local floorObj = sq:addFloor(entry.floor)
                    if floorObj then
                        if isServer() then
                            floorObj:transmitCompleteItemToClients()
                        end
                        applied.objects[#applied.objects + 1] = { square = sq, object = floorObj }
                    end
                end
            end

            if entry.objects then
                for _, rec in ipairs(entry.objects) do
                    local obj = placeSprite(sq, rec.sprite)
                    if obj then
                        applied.objects[#applied.objects + 1] = { square = sq, object = obj }
                        Core.applyContainers(obj, rec)
                        applyAttached(obj, rec)
                    end
                end
            end

            if entry.overlay then
                for _, rec in ipairs(entry.overlay) do
                    local obj = placeOverlay(sq, rec.sprite)
                    if obj then
                        applied.objects[#applied.objects + 1] = { square = sq, object = obj }
                    end
                end
            end
        else
            Util.log("applyArea: target square not loaded at", x, y, z, "- skipped")
        end
    end
    local recalced = {}
    local function squareKey(sq)
        return sq:getX() .. "," .. sq:getY() .. "," .. sq:getZ()
    end
    local function recalcSquare(sq)
        if not sq then return end
        local key = squareKey(sq)
        if recalced[key] then return end
        recalced[key] = true
        sq:RecalcProperties()
        sq:RecalcAllWithNeighbours(true)
    end

    for _, sq in ipairs(touchedSquares) do
        recalcSquare(sq)
    end
    local BORDER_OFFSETS = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }
    for _, entry in ipairs(data.squares) do
        local x, y, z = destX + entry.dx, destY + entry.dy, destZ
        for _, off in ipairs(BORDER_OFFSETS) do
            recalcSquare(cell:getGridSquare(x + off[1], y + off[2], z))
        end
    end

    Util.info("paste:", data.name, "at", destX, destY, destZ, "-", #touchedSquares, "of", #data.squares,
        "squares loaded,", #applied.objects, "changes made",
        isServer() and "(server)" or (isClient() and "(client)" or "(single player)"))
    return true
end

function Core.undoLast()
    local applied = Core.lastApplied
    if not applied or not applied.objects then return false end

    for i = #applied.objects, 1, -1 do
        local item = applied.objects[i]
        local square = item.square
        if square and item.floor then
            local oldSprite = item.oldSprite and getSprite(item.oldSprite)
            if oldSprite then
                item.floor:setSprite(oldSprite)
                if isServer() then
                    item.floor:transmitUpdatedSpriteToClients()
                end
            end
        elseif square and item.object then
            removeSquareObject(square, item.object)
        end
        if square then
            square:RecalcProperties()
            square:RecalcAllWithNeighbours(true)
        end
    end

    Util.info("undo: reverted", #applied.objects, "changes")
    Core.lastApplied = nil
    return true
end

return Core
