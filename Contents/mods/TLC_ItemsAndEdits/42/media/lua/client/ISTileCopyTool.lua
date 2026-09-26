--[[
    ISTileCopyTool.lua  (client)
      - lets the admin drag out a rectangle on the ground (same idea as the
        vanilla "claim safehouse" blue square) to pick the copy area
      - shows a live WxH label while dragging
      - shows a translucent preview of the clipboard's footprint following
        the mouse while in "paste" mode
]]

require "ISUI/ISPanel"
require "TileCopy_Core"

ISTileCopyTool = ISUIElement:derive("ISTileCopyTool")
ISTileCopyTool.instance = nil

local Util = TileCopy.Util
local Core = TileCopy.Core

local TILE_W, TILE_H = 64, 32 -- used for positioning the size label

local function clearHighlights(appliedSquares)
    local cell = getCell()
    if not cell then return end

    for key in pairs(appliedSquares) do
        local x, y, z = key:match("^(%-?%d+),(%-?%d+),(%-?%d+)$")
        if x and y and z then
            local square = cell:getGridSquare(tonumber(x), tonumber(y), tonumber(z))
            if square then
                if square.setHighlight then square:setHighlight(false) end
                local floor = square:getFloor()
                if floor and floor.setHighlighted then floor:setHighlighted(false) end
            end
        end
        appliedSquares[key] = nil
    end
end

local function worldToScreen(x, y, z)
    local player = getPlayer()
    if not player then return nil, nil end
    local playerNum = player:getPlayerNum()
    return isoToScreenX(playerNum, x, y, z), isoToScreenY(playerNum, x, y, z)
end

local function screenToWorld(mx, my, z)
    local screenX = mx
    local screenY = my
    if getMouseXScaled and getMouseYScaled then
        screenX = getMouseXScaled()
        screenY = getMouseYScaled()
    end

    local wx, wy = ISCoordConversion.ToWorld(screenX, screenY, z or 0)
    if wx then return math.floor(wx), math.floor(wy) end
    return nil, nil
end

function ISTileCopyTool:initialise()
    ISUIElement.initialise(self)
end

function ISTileCopyTool:createChildren()
end

function ISTileCopyTool:new()
    local o = ISUIElement:new(0, 0, getCore():getScreenWidth(), getCore():getScreenHeight())
    setmetatable(o, self)
    self.__index = self
    o.mode = nil -- "select" or "paste"
    o.dragStartX, o.dragStartY = nil, nil
    o.dragCurX, o.dragCurY = nil, nil
    o.z = 0
    o.onSelectionMade = nil -- callback(x1,y1,x2,y2,z)
    o.onPasteConfirmed = nil -- callback(x,y,z)
    o.clipboardPreview = nil -- {width=, height=}
    o.appliedHighlights = {}
    o.highlightBounds = nil
    return o
end

function ISTileCopyTool:startSelecting(z, onSelectionMade)
    clearHighlights(self.appliedHighlights)
    self.highlightBounds = nil
    self.mode = "select"
    self.z = z or getPlayer():getZ()
    self.dragStartX, self.dragStartY = nil, nil
    self.onSelectionMade = onSelectionMade
    self:setVisible(true)
    self:bringToTop()
end

function ISTileCopyTool:startPasting(z, clipboardData, onPasteConfirmed)
    clearHighlights(self.appliedHighlights)
    self.highlightBounds = nil
    self.mode = "paste"
    self.z = z or getPlayer():getZ()
    self.clipboardPreview = clipboardData
    self.onPasteConfirmed = onPasteConfirmed
    self:setVisible(true)
    self:bringToTop()
end

function ISTileCopyTool:cancel()
    clearHighlights(self.appliedHighlights)
    self.highlightBounds = nil
    self.mode = nil
    self.dragStartX, self.dragStartY = nil, nil
    self:setVisible(false)
end

function ISTileCopyTool:onMouseDown(mx, my)
    if self.mode == "select" then
        local wx, wy = screenToWorld(mx, my, self.z)
        if wx then
            self.dragStartX, self.dragStartY = wx, wy
            self.dragCurX, self.dragCurY = wx, wy
        end
        return true
    elseif self.mode == "paste" then
        local wx, wy = screenToWorld(mx, my, self.z)
        if wx and self.onPasteConfirmed then
            self.onPasteConfirmed(wx, wy, self.z)
        end
        return true
    end
    return false
end

function ISTileCopyTool:onMouseUp(mx, my)
    if self.mode == "select" and self.dragStartX then
        local wx, wy = screenToWorld(mx, my, self.z)
        if wx and self.onSelectionMade then
            self.onSelectionMade(self.dragStartX, self.dragStartY, wx, wy, self.z)
        end
        self.dragStartX, self.dragStartY = nil, nil
    end
    return true
end

function ISTileCopyTool:onMouseMove(dx, dy)
    if self.mode == "select" and self.dragStartX then
        local wx, wy = screenToWorld(getMouseX(), getMouseY(), self.z)
        if wx then
            self.dragCurX, self.dragCurY = wx, wy
        end
    end
    return true
end

--- Highlights a rectangle of world tiles and labels its dimensions.
function ISTileCopyTool:drawWorldRect(x1, y1, x2, y2, z)
    local minX, maxX = math.min(x1, x2), math.max(x1, x2)
    local minY, maxY = math.min(y1, y2), math.max(y1, y2)
    local boundsKey = table.concat({ minX, minY, maxX, maxY, z }, ",")

    if self.highlightBounds ~= boundsKey then
        clearHighlights(self.appliedHighlights)
        local cell = getCell()
        if cell then
            for gx = minX, maxX do
                for gy = minY, maxY do
                    local square = cell:getGridSquare(gx, gy, z)
                    if square then
                        local floor = square:getFloor()
                        if floor and floor.setHighlightColor then
                            floor:setHighlightColor(0.15, 0.45, 1.0, 0.55)
                        end
                        if floor and floor.setHighlighted then
                            floor:setHighlighted(true, false)
                        end
                        if square.setHighlight then
                            square:setHighlight(true)
                        end
                        self.appliedHighlights[gx .. "," .. gy .. "," .. z] = true
                    end
                end
            end
        end
        self.highlightBounds = boundsKey
    end

    -- Keep a screen-space size label over the highlighted area.
    local tlx, tly = worldToScreen(minX, minY, z)
    if tlx then
        local w, h = (maxX - minX + 1), (maxY - minY + 1)
        self:drawText(w .. " x " .. h, tlx - TILE_W / 2, tly - TILE_H, 1, 1, 1, 1, UIFont.Small)
    end
end

function ISTileCopyTool:render()
    if self.mode == "select" and self.dragStartX then
        self:drawWorldRect(self.dragStartX, self.dragStartY, self.dragCurX or self.dragStartX, self.dragCurY or self.dragStartY, self.z)
    elseif self.mode == "paste" and self.clipboardPreview then
        local wx, wy = screenToWorld(getMouseX(), getMouseY(), self.z)
        if wx then
            local w = self.clipboardPreview.width or 1
            local h = self.clipboardPreview.height or 1
            self:drawWorldRect(wx, wy, wx + w - 1, wy + h - 1, self.z)
        end
    end
end

function ISTileCopyTool.OnGameStart()
    if ISTileCopyTool.instance then return end
    local inst = ISTileCopyTool:new()
    inst:initialise()
    inst:setVisible(false)
    inst:addToUIManager()
    ISTileCopyTool.instance = inst
end

Events.OnGameStart.Add(ISTileCopyTool.OnGameStart)
