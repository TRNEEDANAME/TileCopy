--[[
    TileCopy_ServerCommands.lua  (server)

    Receives paste requests from clients, re-checks admin rights on the
    authoritative side (never trust the client, they always lie), and if valid, applies the
    change server-side. Core.applyArea/undoLast transmit every object they
    add/remove to all clients themselves
]]

require "TileCopy_Core"

local Util = TileCopy.Util
local Core = TileCopy.Core

local function onClientCommand(module, command, playerObj, args)
    if module ~= "TileCopy" then return end

    if command == "paste" then
        if not Util.isAdmin(playerObj) then
            sendServerCommand(playerObj, "TileCopy", "denied", {})
            return
        end
        if not args or not args.data then return end

        Core.applyArea(args.data, args.x, args.y, args.z)

        sendServerCommand(playerObj, "TileCopy", "pasted", {})
    elseif command == "undo" then
        if not Util.isAdmin(playerObj) then
            sendServerCommand(playerObj, "TileCopy", "denied", {})
            return
        end

        if Core.undoLast() then
            sendServerCommand(playerObj, "TileCopy", "undone", {})
        end
    end
end

Events.OnClientCommand.Add(onClientCommand)
