local json = require("json")
local logger = require("logger")
local https = require("ssl.https")
local http = require("socket.http")
local ltn12 = require("ltn12")

local BookWyrmClient = {}

function BookWyrmClient:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    o._author_cache = o:_loadAuthorCache()
    o._cache_dirty = false
    return o
end

function BookWyrmClient:_authorCachePath()
    local DataStorage = require("datastorage")
    return DataStorage:getSettingsDir() .. "/bookwyrm_authors.json"
end

function BookWyrmClient:_loadAuthorCache()
    local path = self:_authorCachePath()
    local f = io.open(path, "r")
    if not f then return {} end
    local content = f:read("*a")
    f:close()
    local ok, data = pcall(json.decode, content)
    if ok and type(data) == "table" then
        logger.dbg("BookWyrm: loaded", #data, "cached authors from disk")
        return data
    end
    return {}
end

function BookWyrmClient:saveAuthorCache()
    if not self._cache_dirty then return end
    local path = self:_authorCachePath()
    local f = io.open(path, "w")
    if f then
        f:write(json.encode(self._author_cache))
        f:close()
        self._cache_dirty = false
    end
end

--- Perform a GET request with ActivityPub Accept header.
-- Returns parsed JSON table or nil + error string.
function BookWyrmClient:get(url)
    local chunks = {}
    local request_fn = url:match("^https") and https.request or http.request

    local _, status_code, _headers = request_fn({
        url = url,
        method = "GET",
        headers = {
            ["Accept"] = "application/activity+json",
            ["User-Agent"] = "KOReader-BookWyrm/0.1",
        },
        sink = ltn12.sink.table(chunks),
        timeout = 15,
    })

    if not status_code or status_code ~= 200 then
        logger.warn("BookWyrm: HTTP", status_code, "for", url)
        return nil, "HTTP " .. tostring(status_code)
    end

    local body = table.concat(chunks)
    local ok, data = pcall(json.decode, body)
    if not ok then
        logger.warn("BookWyrm: JSON parse error for", url)
        return nil, "JSON parse error"
    end

    return data
end

--- Fetch the name of an author by their AP URI.
-- Caches results so each author is only fetched once per session.
function BookWyrmClient:getAuthorName(author_url)
    if self._author_cache[author_url] then
        return self._author_cache[author_url]
    end

    -- Append .json if the URL doesn't already end with it
    local url = author_url
    if not url:match("%.json$") then
        url = url .. ".json"
    end

    local data, err = self:get(url)
    if not data then
        logger.warn("BookWyrm: failed to fetch author", author_url, err)
        return nil
    end

    local name = data.name or data.preferredUsername or "Unknown"
    self._author_cache[author_url] = name
    self._cache_dirty = true
    return name
end

--- Resolve a list of author URIs into a comma-separated name string.
function BookWyrmClient:resolveAuthors(author_urls)
    if not author_urls or #author_urls == 0 then return "" end

    local names = {}
    for _, url in ipairs(author_urls) do
        if type(url) == "string" then
            local name = self:getAuthorName(url)
            if name then table.insert(names, name) end
        elseif type(url) == "table" then
            -- In case BookWyrm ever inlines the author object
            local name = url.name or url.preferredUsername
            if name then table.insert(names, name) end
        end
    end

    return table.concat(names, ", ")
end

--- Fetch just the shelf metadata (name + total count), no books.
function BookWyrmClient:getShelfInfo(instance_url, username, shelf_id)
    local url = instance_url .. "/user/" .. username .. "/shelf/" .. shelf_id .. ".json"
    local data, err = self:get(url)
    if not data then return nil, err end
    return {
        name = data.name or shelf_id,
        total = data.totalItems or 0,
        shelf_id = shelf_id,
    }
end

--- Fetch a single shelf and its first page of books.
-- Shelf identifiers: "to-read", "reading", "read", "stopped-reading"
function BookWyrmClient:getShelf(instance_url, username, shelf_id, max_pages, progress_cb)
    max_pages = max_pages or 1
    local url = instance_url .. "/user/" .. username .. "/shelf/" .. shelf_id .. ".json"
    local data, err = self:get(url)
    if not data then return nil, err end

    local books = {}
    local page_url = data.first
    local pages_fetched = 0
    local total = data.totalItems or 0

    while page_url and pages_fetched < max_pages do
        if not page_url:match("^https?://") then
            page_url = instance_url .. page_url
        end

        local page, page_err = self:get(page_url)
        if not page then
            logger.warn("BookWyrm: failed to fetch page", page_url, page_err)
            break
        end

        if page.orderedItems then
            for _, item in ipairs(page.orderedItems) do
                local book = self:parseBook(item)
                if book then table.insert(books, book) end
            end
        end

        pages_fetched = pages_fetched + 1
        if progress_cb then
            progress_cb(#books, total)
        end
        page_url = page.next
    end

    return {
        name = data.name or shelf_id,
        total = total,
        books = books,
    }
end

--- Parse a BookWyrm Edition AP object into a simple book record.
function BookWyrmClient:parseBook(ap_object)
    if not ap_object or ap_object.type ~= "Edition" then return nil end
    return {
        title = ap_object.title or "Unknown",
        subtitle = ap_object.subtitle ~= "" and ap_object.subtitle or nil,
        author_urls = ap_object.authors or {},
        authors = nil,  -- resolved lazily via resolveAuthors
        isbn_13 = ap_object.isbn13,
        isbn_10 = ap_object.isbn10,
        cover_url = ap_object.cover and ap_object.cover.url or nil,
        format = ap_object.physicalFormat,
        published = ap_object.publishedDate,
        bw_id = ap_object.id,
        ol_key = ap_object.openlibraryKey,
    }
end

--- Fetch all four default shelves (first page each).
function BookWyrmClient:getAllShelves(instance_url, username, resolve_authors)
    local shelf_ids = { "reading", "to-read", "read", "stopped-reading" }
    local shelves = {}
    for _, sid in ipairs(shelf_ids) do
        local shelf, err = self:getShelf(instance_url, username, sid, 1)
        if shelf then
            if resolve_authors then
                for _, book in ipairs(shelf.books) do
                    book.authors = self:resolveAuthors(book.author_urls)
                end
            end
            shelves[sid] = shelf
        else
            logger.warn("BookWyrm: failed to fetch shelf", sid, err)
            shelves[sid] = { name = sid, total = 0, books = {} }
        end
    end
    return shelves
end

return BookWyrmClient
