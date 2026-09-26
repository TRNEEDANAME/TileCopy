--[[
    ISTileCopyStringUI.lua  (client)

    Two tiny popups built around a single text field:
      - ISTileCopyStringUI.showExport(str)       shows str pre-selected so
                                                  the admin can just Ctrl+C it
      - ISTileCopyStringUI.showImport(onImport)  lets the admin paste a
                                                  string and calls
                                                  onImport(data) once it
                                                  decodes successfully
]]

require "ISUI/ISPanel"
require "ISUI/ISButton"
require "ISUI/ISLabel"
require "ISUI/ISTextEntryBox"

ISTileCopyStringUI = ISPanel:derive("ISTileCopyStringUI")

local PANEL_W, PANEL_H = 420, 150
local PADDING = 10

function ISTileCopyStringUI:initialise()
    ISPanel.initialise(self)
end

function ISTileCopyStringUI:createChildren()
    ISPanel.createChildren(self)

    local pad = PADDING
    local y = pad

    self.titleLabel = ISLabel:new(pad, y, 20, self.titleText, 1, 1, 1, 1, UIFont.Medium, true)
    self:addChild(self.titleLabel)
    y = y + 24

    self.hintLabel = ISLabel:new(pad, y, 20, self.hintText, 0.8, 0.8, 0.8, 1, UIFont.Small, true)
    self:addChild(self.hintLabel)
    y = y + 20

    -- A copied area can be tens of thousands of characters, which a text
    -- box truncates / chokes on so I have to do this little fuckery to make it work.
    -- Didn't test copying Louisville but that's what bug reports are for
    if self.readOnly then
        local len = #(self.initialText or "")
        self.infoLabel = ISLabel:new(pad, y + 4, 20, "String length: " .. len .. " characters", 1, 1, 1, 1, UIFont.Small, true)
        self:addChild(self.infoLabel)
    else
        self.entry = ISTextEntryBox:new("", pad, y, self.width - pad * 2, 25)
        self.entry:initialise()
        self.entry:instantiate()
        self.entry:setMaxTextLength(10000000)
        self:addChild(self.entry)
    end
    y = y + 30

    local btnW = (self.width - pad * 4) / 3

    if self.readOnly then
        self.actionBtn = ISButton:new(pad, y, btnW, 25, "Copy to Clipboard", self, ISTileCopyStringUI.onCopyToClipboard)
    else
        self.actionBtn = ISButton:new(pad, y, btnW, 25, "Import", self, ISTileCopyStringUI.onImport)
    end
    self.actionBtn:initialise()
    self:addChild(self.actionBtn)

    if not self.readOnly then
        self.pasteBtn = ISButton:new(pad * 2 + btnW, y, btnW, 25, "Import Clipboard", self, ISTileCopyStringUI.onImportClipboard)
        self.pasteBtn:initialise()
        self:addChild(self.pasteBtn)
    end

    self.closeBtn = ISButton:new(pad * 3 + btnW * 2, y, btnW, 25, "Close", self, ISTileCopyStringUI.onClose)
    self.closeBtn:initialise()
    self:addChild(self.closeBtn)
    y = y + 30

    self.statusLabel = ISLabel:new(pad, y, 20, "", 1, 0.5, 0.5, 1, UIFont.Small, true)
    self:addChild(self.statusLabel)
end

function ISTileCopyStringUI:onCopyToClipboard()
    local Util = TileCopy.Util
    local text = self.initialText or ""
    Util.info("clipboard: setting", Util.preview(text))
    Clipboard.setClipboard(text)

    -- Read it straight back to catch a clipboard that truncates/alters it.
    local back = Clipboard.getClipboard()
    if back == text then
        Util.info("clipboard: read-back matches (" .. #text .. " chars)")
    else
        Util.info("clipboard: read-back DIFFERS - sent", #text, "chars, got back", Util.preview(back))
    end
    self.statusLabel:setName("Copied " .. #text .. " characters to the clipboard.")
end

function ISTileCopyStringUI:onImportClipboard()
    local Util = TileCopy.Util
    local text = Clipboard.getClipboard()
    Util.info("clipboard: got", Util.preview(text))
    if not text or text == "" then
        self.statusLabel:setName("Clipboard is empty or unreadable.")
        return
    end
    self:importText(text)
end

function ISTileCopyStringUI:onImport()
    local text = self.entry:getText()
    TileCopy.Util.log("import box: got", TileCopy.Util.preview(text))
    self:importText(text)
end

function ISTileCopyStringUI:importText(text)
    local data, err = TileCopy.Core.areaFromString(text)
    if not data then
        self.statusLabel:setName("Import failed: " .. tostring(err))
        TileCopy.Util.log("Import failed: " .. tostring(err))
        return
    end
    if self.onImportCallback then
        self.onImportCallback(data)
    end
    self:onClose()
end

function ISTileCopyStringUI:onClose()
    self:setVisible(false)
    self:removeFromUIManager()
end

function ISTileCopyStringUI:new(x, y, opts)
    local o = ISPanel:new(x, y, PANEL_W, PANEL_H)
    setmetatable(o, self)
    self.__index = self
    o.moveWithMouse = true
    o.backgroundColor = { r = 0, g = 0, b = 0, a = 0.9 }
    o.borderColor = { r = 0.4, g = 0.4, b = 0.4, a = 1 }
    o.titleText = opts.titleText
    o.hintText = opts.hintText
    o.initialText = opts.initialText
    o.readOnly = opts.readOnly
    o.onImportCallback = opts.onImportCallback
    return o
end

--- Shows a box pre-filled with `str`, selected so the admin can hit Ctrl+C.
function ISTileCopyStringUI.showExport(str)
    local x = getCore():getScreenWidth() / 2 - PANEL_W / 2
    local y = getCore():getScreenHeight() / 2 - PANEL_H / 2
    local inst = ISTileCopyStringUI:new(x, y, {
        titleText = "Copy this string",
        hintText = "Already copied to your clipboard.",
        initialText = str,
        readOnly = true,
    })
    inst:initialise()
    inst:addToUIManager()
    inst:setVisible(true)
    inst:bringToTop()
    inst:onCopyToClipboard()
    return inst
end

--- Shows an empty box for pasting a string. Calls onImport(data) once the
--- text decodes into a valid captured area.
function ISTileCopyStringUI.showImport(onImport)
    local x = getCore():getScreenWidth() / 2 - PANEL_W / 2
    local y = getCore():getScreenHeight() / 2 - PANEL_H / 2
    local inst = ISTileCopyStringUI:new(x, y, {
        titleText = "Paste a Tile Copy string",
        hintText = "Click Import Clipboard, or paste into the box and click Import.",
        initialText = "",
        readOnly = false,
        onImportCallback = onImport,
    })
    inst:initialise()
    inst:addToUIManager()
    inst:setVisible(true)
    inst:bringToTop()
    return inst
end
