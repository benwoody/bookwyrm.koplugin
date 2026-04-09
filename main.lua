--[[--
BookWyrm plugin for KOReader.

Read-only view of your BookWyrm shelves via ActivityPub.

@module koplugin.bookwyrm
--]]

local InfoMessage = require("ui/widget/infomessage")
local Menu = require("ui/widget/menu")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local BookWyrm = WidgetContainer:extend{
    name = "bookwyrm",
    is_doc_only = false,
}

function BookWyrm:init()
    self.settings = G_reader_settings:readSetting("bookwyrm", {
        instance_url = nil,
        username = nil,
    })
    self.ui.menu:registerToMainMenu(self)
end

function BookWyrm:addToMainMenu(menu_items)
    menu_items.bookwyrm = {
        text = _("BookWyrm"),
        sorting_hint = "tools",
        callback = function()
            self:showHome()
        end,
    }
end

--- Helper to create a fullscreen menu with consistent style.
-- back_action: function to call when back (left icon) is tapped. nil = no back icon.
function BookWyrm:_fullscreenMenu(title, items, back_action)
    local menu
    menu = Menu:new{
        title = title,
        is_popout = false,
        is_borderless = true,
        covers_fullscreen = true,
        title_bar_fm_style = true,
        title_bar_left_icon = back_action and "chevron.left" or nil,
        item_table = items,
        close_callback = function()
            UIManager:close(menu)
        end,
    }
    if back_action then
        function menu:onLeftButtonTap()
            UIManager:close(menu)
            back_action()
        end
    end
    UIManager:show(menu)
    return menu
end

function BookWyrm:showSettingsDialog(on_close)
    local dialog
    dialog = MultiInputDialog:new{
        title = _("BookWyrm settings"),
        fields = {
            {
                text = self.settings.instance_url or "",
                hint = _("Instance URL (e.g. https://bookwyrm.social)"),
            },
            {
                text = self.settings.username or "",
                hint = _("Username"),
            },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                        if on_close then on_close() end
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local fields = dialog:getFields()
                        local url = fields[1]:gsub("/$", "")
                        self.settings.instance_url = url ~= "" and url or nil
                        self.settings.username = fields[2] ~= "" and fields[2] or nil
                        G_reader_settings:saveSetting("bookwyrm", self.settings)
                        UIManager:close(dialog)
                        UIManager:show(InfoMessage:new{
                            text = _("BookWyrm settings saved."),
                            timeout = 2,
                        })
                        if on_close then on_close() end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function BookWyrm:isConfigured()
    return self.settings.instance_url and self.settings.username
end

function BookWyrm:getClient()
    if not self._client then
        local BookWyrmClient = require("bookwyrmclient")
        self._client = BookWyrmClient:new()
    end
    return self._client
end

function BookWyrm:withNetwork(callback)
    if not self:isConfigured() then
        UIManager:show(InfoMessage:new{
            text = _("Please configure your BookWyrm instance and username first."),
        })
        return
    end

    if NetworkMgr:isOnline() then
        callback()
    else
        NetworkMgr:turnOnWifiAndWaitForConnection(callback)
    end
end

-- ============================================================
-- Navigation
-- Home → Shelves → Shelf Books
-- Home → Reading Queue
-- Back re-creates the parent. X exits to file browser.
-- ============================================================

function BookWyrm:showHome()
    self:_fullscreenMenu(_("BookWyrm"), {
        {
            text = _("View shelves"),
            callback = function() self:viewShelves() end,
        },
        {
            text = _("Reading queue"),
            callback = function() self:showReadingQueue() end,
        },
        {
            text = _("Settings"),
            callback = function()
                self:showSettingsDialog(function() self:showHome() end)
            end,
        },
    })
end

function BookWyrm:viewShelves()
    self:withNetwork(function()
        UIManager:show(InfoMessage:new{
            text = _("Fetching shelves…"),
            timeout = 1,
        })

        UIManager:nextTick(function()
            local client = self:getClient()
            local shelf_ids = { "reading", "to-read", "read", "stopped-reading" }
            local items = {}

            for _i, sid in ipairs(shelf_ids) do
                local info = client:getShelfInfo(
                    self.settings.instance_url,
                    self.settings.username,
                    sid
                )
                if info then
                    table.insert(items, {
                        text = T("%1 (%2)", info.name, info.total),
                        callback = function()
                            self:viewShelfBooks(info.shelf_id, info.name)
                        end,
                    })
                end
            end

            self:_fullscreenMenu(
                _("BookWyrm shelves"),
                items,
                function() self:showHome() end  -- back → Home
            )
        end)
    end)
end

--- Update a loading message in-place by closing and re-showing.
function BookWyrm:_updateLoading(loading_ref, text)
    if loading_ref[1] then
        UIManager:close(loading_ref[1])
    end
    loading_ref[1] = InfoMessage:new{ text = text }
    UIManager:show(loading_ref[1])
    UIManager:forceRePaint()
end

--- Resolve author names for a list of books, showing progress.
-- Returns the books list with authors populated.
function BookWyrm:_resolveBookAuthors(client, books)
    local loading = { InfoMessage:new{
        text = T(_("Resolving authors…\n0 of %1"), #books),
    } }
    UIManager:show(loading[1])
    UIManager:forceRePaint()
    for i, book in ipairs(books) do
        book.authors = client:resolveAuthors(book.author_urls)
        if i % 5 == 0 then
            self:_updateLoading(loading,
                T(_("Resolving authors…\n%1 of %2"), i, #books))
        end
    end
    UIManager:close(loading[1])
    client:saveAuthorCache()
    return books
end

function BookWyrm:viewShelfBooks(shelf_id, shelf_name)
    local loading = { InfoMessage:new{
        text = T(_("Loading %1…"), shelf_name),
    } }
    UIManager:show(loading[1])

    UIManager:nextTick(function()
        local client = self:getClient()
        local shelf = client:getShelf(
            self.settings.instance_url,
            self.settings.username,
            shelf_id,
            50,
            function(fetched, total)
                self:_updateLoading(loading,
                    T(_("Loading %1…\n%2 of %3 books"), shelf_name, fetched, total))
            end
        )
        UIManager:close(loading[1])

        if not shelf or #shelf.books == 0 then
            UIManager:show(InfoMessage:new{
                text = T(_("%1 is empty."), shelf_name),
                timeout = 2,
            })
            self:viewShelves()
            return
        end

        self:_resolveBookAuthors(client, shelf.books)
        self:_showShelfBooks(shelf.books, shelf_name, shelf.total)
    end)
end

--- Display a cached list of shelf books. Tapping a book shows info then
-- re-opens this same view (no network needed).
function BookWyrm:_showShelfBooks(books, shelf_name, total)
    local LocalBooks = require("localbooks")
    local local_index = LocalBooks:getAll()

    local items = {}
    for _i, book in ipairs(books) do
        local local_match = LocalBooks:match(book, local_index)
        local entry = book.title
        if book.authors and book.authors ~= "" then
            entry = entry .. " — " .. book.authors
        end
        if local_match and local_match.file then
            entry = "▸ " .. entry
        end
        local filepath = local_match and local_match.file or nil
        table.insert(items, {
            text = entry,
            callback = function()
                self:showBookInfo(book, filepath, function()
                    self:_showShelfBooks(books, shelf_name, total)
                end)
            end,
        })
    end

    self:_fullscreenMenu(
        T("%1 (%2)", shelf_name, total),
        items,
        function() self:viewShelves() end
    )
end

function BookWyrm:showReadingQueue()
    local LocalBooks = require("localbooks")
    local local_index = LocalBooks:getAll()
    local isbn_count = 0
    for _k in pairs(local_index.by_isbn) do isbn_count = isbn_count + 1 end
    local title_count = 0
    for _k in pairs(local_index.by_title) do title_count = title_count + 1 end
    logger.dbg("BookWyrm: local index:", isbn_count, "ISBNs,", title_count, "titles")

    self:withNetwork(function()
        local loading = { InfoMessage:new{
            text = _("Fetching currently reading…"),
        } }
        UIManager:show(loading[1])

        UIManager:nextTick(function()
            local client = self:getClient()

            local reading = client:getShelf(
                self.settings.instance_url, self.settings.username, "reading", 5,
                function(fetched, total)
                    self:_updateLoading(loading,
                        T(_("Currently reading…\n%1 of %2 books"), fetched, total))
                end)

            self:_updateLoading(loading, _("Fetching to-read shelf…"))

            local to_read = client:getShelf(
                self.settings.instance_url, self.settings.username, "to-read", 50,
                function(fetched, total)
                    self:_updateLoading(loading,
                        T(_("To read…\n%1 of %2 books"), fetched, total))
                end)
            UIManager:close(loading[1])

            local all_books = {}
            if reading then
                for _i, book in ipairs(reading.books) do
                    table.insert(all_books, book)
                end
            end
            if to_read then
                for _i, book in ipairs(to_read.books) do
                    table.insert(all_books, book)
                end
            end
            self:_resolveBookAuthors(client, all_books)

            local items = {}
            local owned_items = {}
            local unowned_items = {}

            for _i, book in ipairs(all_books) do
                local local_match = LocalBooks:match(book, local_index)
                if local_match then
                    table.insert(owned_items, { bw = book, local_data = local_match })
                else
                    table.insert(unowned_items, { bw = book })
                end
            end

            if #owned_items > 0 then
                table.insert(items, {
                    text = T(_("On this Kindle (%1)"), #owned_items),
                    bold = true,
                    callback = function() end,
                })
                for _i, item in ipairs(owned_items) do
                    local label = item.bw.title
                    local stats = {}
                    if item.local_data.percent_finished then
                        local pct = math.floor(item.local_data.percent_finished * 100)
                        table.insert(stats, pct .. "%")
                    end
                    local time_str = LocalBooks:formatTime(item.local_data.total_read_time)
                    if time_str then
                        table.insert(stats, time_str)
                    end
                    if #stats > 0 then
                        label = label .. "  [" .. table.concat(stats, ", ") .. "]"
                    end
                    if item.bw.authors and item.bw.authors ~= "" then
                        label = label .. "\n    " .. item.bw.authors
                    end
                    table.insert(items, {
                        text = "▸ " .. label,
                        callback = function()
                            if item.local_data.file then
                                self:openBook(item.local_data.file)
                            else
                                self:showBookInfo(item.bw)
                            end
                        end,
                    })
                end
            end

            if #unowned_items > 0 then
                table.insert(items, {
                    text = T(_("Not on this Kindle (%1)"), #unowned_items),
                    bold = true,
                    callback = function() end,
                })
                for _i, item in ipairs(unowned_items) do
                    local label = item.bw.title
                    if item.bw.authors and item.bw.authors ~= "" then
                        label = label .. " — " .. item.bw.authors
                    end
                    table.insert(items, {
                        text = "  " .. label,
                        callback = function()
                            self:showBookInfo(item.bw)
                        end,
                    })
                end
            end

            if #items == 0 then
                UIManager:show(InfoMessage:new{
                    text = _("Your reading queue is empty."),
                })
                return
            end

            local total_bw = (to_read and to_read.total or 0) + (reading and reading.total or 0)
            self:_fullscreenMenu(
                T(_("Reading queue (%1 books)"), total_bw),
                items,
                function() self:showHome() end  -- back → Home
            )
        end)
    end)
end

function BookWyrm:showBookInfo(book, filepath, on_close)
    local lines = { book.title }
    if book.subtitle then
        table.insert(lines, book.subtitle)
    end
    if book.authors and book.authors ~= "" then
        table.insert(lines, _("by ") .. book.authors)
    end
    if book.isbn_13 then
        table.insert(lines, "ISBN: " .. book.isbn_13)
    elseif book.isbn_10 then
        table.insert(lines, "ISBN: " .. book.isbn_10)
    end
    if book.format then
        table.insert(lines, _("Format: ") .. book.format)
    end
    if book.published and book.published ~= "" then
        table.insert(lines, _("Published: ") .. book.published)
    end

    if filepath then
        local ButtonDialog = require("ui/widget/buttondialog")
        local dialog
        dialog = ButtonDialog:new{
            title = table.concat(lines, "\n"),
            buttons = {
                {
                    {
                        text = _("Open book"),
                        callback = function()
                            UIManager:close(dialog)
                            self:openBook(filepath)
                        end,
                    },
                    {
                        text = _("Close"),
                        callback = function()
                            UIManager:close(dialog)
                            if on_close then on_close() end
                        end,
                    },
                },
            },
        }
        UIManager:show(dialog)
    else
        UIManager:show(InfoMessage:new{
            text = table.concat(lines, "\n"),
        })
        if on_close then on_close() end
    end
end

function BookWyrm:openBook(filepath)
    logger.dbg("BookWyrm: trying to open:", filepath)
    local lfs = require("libs/libkoreader-lfs")
    if lfs.attributes(filepath, "mode") ~= "file" then
        logger.warn("BookWyrm: file not found:", filepath)
        UIManager:show(InfoMessage:new{
            text = T(_("File not found:\n%1"), filepath),
            timeout = 3,
        })
        return
    end
    local ReaderUI = require("apps/reader/readerui")
    ReaderUI:showReader(filepath)
end

return BookWyrm
