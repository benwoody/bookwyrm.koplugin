local DataStorage = require("datastorage")
local logger = require("logger")
local SQ3 = require("lua-ljsqlite3/init")

local LocalBooks = {}

--- Extract ISBN from an identifier string.
-- Handles formats like "urn:isbn:9781436272025", "978-1-4362-7202-5",
-- bare "9781436272025", Calibre UUIDs (skipped), etc.
function LocalBooks:extractISBN(identifier)
    if not identifier or identifier == "" then return nil end
    -- Skip UUIDs — they can contain digit sequences that look like ISBNs
    if identifier:match("^urn:uuid:") or identifier:match("%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$") then
        return nil
    end
    -- Strip common prefixes
    local s = identifier:gsub("^urn:isbn:", ""):gsub("^isbn:", "")
    -- Try ISBN-13 (13 digits, with or without dashes)
    local raw13 = s:match("(%d[%d%-]+%d)")
    if raw13 then
        local isbn13 = raw13:gsub("-", "")
        if #isbn13 == 13 then return isbn13 end
    end
    -- Try ISBN-10 (9 digits + check digit, with or without dashes)
    local raw10 = s:match("(%d[%d%-]+[%dXx])")
    if raw10 then
        local isbn10 = raw10:gsub("-", "")
        if #isbn10 == 10 then return isbn10 end
    end
    -- Brute force: find any 13-digit or 10-digit number in the string
    local bare13 = identifier:match("(%d%d%d%d%d%d%d%d%d%d%d%d%d)")
    if bare13 then return bare13 end
    local bare10 = identifier:match("(%d%d%d%d%d%d%d%d%d[%dXx])")
    if bare10 then return bare10 end
    return nil
end

--- Scan all local books using CoverBrowser cache (primary) and ReadHistory (fallback).
-- Returns { by_isbn = { ["9781436272025"] = entry }, by_title = { ["normalized"] = entry } }
function LocalBooks:getAll()
    local by_isbn = {}
    local by_title = {}

    -- Step 1: Read stats from statistics DB, keyed by normalized title
    local stats_by_title = self:_getStatsMap()

    -- Step 2: Get all books from CoverBrowser cache (covers every book on device)
    local cache_books = self:_getCoverBrowserBooks()

    -- Step 3: Get percent_finished and ISBN from DocSettings for opened books
    local ok_ds, DocSettings = pcall(require, "docsettings")
    local lfs = require("libs/libkoreader-lfs")

    for _i, cb in ipairs(cache_books) do
        local norm_title = self:normalizeTitle(cb.title)
        local stats = stats_by_title[norm_title] or {}
        local isbn = nil
        local percent_finished = nil

        -- Try DocSettings for ISBN and progress (only exists for opened books)
        if ok_ds and DocSettings and DocSettings:hasSidecarFile(cb.file) then
            local dsettings = DocSettings:open(cb.file)
            if dsettings then
                local doc_props = dsettings:readSetting("doc_props")
                if doc_props then
                    isbn = self:extractISBN(doc_props.identifier)
                    if not isbn and doc_props.keywords then
                        isbn = self:extractISBN(doc_props.keywords)
                    end
                end
                percent_finished = dsettings:readSetting("percent_finished")
            end
        end

        local entry = {
            title = cb.title,
            authors = cb.authors or stats.authors or "",
            isbn = isbn,
            file = cb.file,
            file_exists = cb.file and lfs.attributes(cb.file, "mode") == "file" or false,
            percent_finished = percent_finished,
            total_read_time = stats.total_read_time or 0,
            total_read_pages = stats.total_read_pages or 0,
            highlights = stats.highlights or 0,
            notes = stats.notes or 0,
        }

        if isbn then
            by_isbn[isbn] = entry
        end
        if norm_title ~= "" then
            by_title[norm_title] = entry
        end
    end

    -- Merge ReadHistory: override file paths for known books,
    -- AND add books that CoverBrowser missed entirely
    local ok_rh, ReadHistory = pcall(require, "readhistory")
    if ok_rh and ReadHistory then
        for _i, hist_entry in ipairs(ReadHistory.hist or {}) do
            if hist_entry.file then
                local hist_title = nil
                local hist_authors = ""
                local hist_isbn = nil
                local hist_pf = nil
                if ok_ds and DocSettings and DocSettings:hasSidecarFile(hist_entry.file) then
                    local ds = DocSettings:open(hist_entry.file)
                    if ds then
                        local dp = ds:readSetting("doc_props")
                        if dp then
                            hist_title = dp.title
                            hist_authors = dp.authors or ""
                            hist_isbn = self:extractISBN(dp.identifier)
                        end
                        hist_pf = ds:readSetting("percent_finished")
                    end
                end
                if not hist_title or hist_title == "" then
                    hist_title = hist_entry.file:match("([^/]+)%.[^%.]+$") or ""
                end
                local key = self:normalizeTitle(hist_title)
                if key ~= "" then
                    if by_title[key] then
                        -- Book exists: override with correct file path
                        by_title[key].file = hist_entry.file
                        by_title[key].file_exists = hist_entry.file and lfs.attributes(hist_entry.file, "mode") == "file" or false
                    else
                        -- Book missing from CoverBrowser: add it
                        local entry = {
                            title = hist_title,
                            authors = hist_authors,
                            isbn = hist_isbn,
                            file = hist_entry.file,
                            file_exists = hist_entry.file and lfs.attributes(hist_entry.file, "mode") == "file" or false,
                            percent_finished = hist_pf,
                            total_read_time = 0,
                            total_read_pages = 0,
                        }
                        by_title[key] = entry
                        if hist_isbn then
                            by_isbn[hist_isbn] = entry
                        end
                    end
                end
            end
        end
    end

    return { by_isbn = by_isbn, by_title = by_title }
end

--- Query CoverBrowser's bookinfo_cache.sqlite3 for all known books.
-- Returns a list of { title, authors, file } entries.
function LocalBooks:_getCoverBrowserBooks()
    local books = {}
    local db_path = DataStorage:getSettingsDir() .. "/bookinfo_cache.sqlite3"
    local ok, db = pcall(SQ3.open, db_path, "ro")
    if not ok or not db then
        logger.warn("BookWyrm: no bookinfo_cache.sqlite3, falling back to ReadHistory")
        return self:_getReadHistoryBooks()
    end

    local query_ok, err = pcall(function()
        local stmt = db:prepare([[
            SELECT directory, filename, title, authors
            FROM bookinfo
            WHERE filename IS NOT NULL AND filename != ''
        ]])
        if not stmt then return end
        for row in stmt:rows() do
            local dir = row[1] or ""
            local fname = row[2] or ""
            local title = row[3]
            if not title or title == "" then
                title = fname:match("([^/]+)%.[^%.]+$") or fname
            end
            table.insert(books, {
                title = title,
                authors = row[4] or "",
                file = dir:gsub("/$", "") .. "/" .. fname,
            })
        end
        stmt:close()
    end)

    db:close()

    if not query_ok then
        logger.warn("BookWyrm: bookinfo_cache query error:", err)
        return self:_getReadHistoryBooks()
    end

    if #books == 0 then
        return self:_getReadHistoryBooks()
    end

    return books
end

--- Fallback: get books from ReadHistory if CoverBrowser cache isn't available.
function LocalBooks:_getReadHistoryBooks()
    local books = {}
    local ok_rh, ReadHistory = pcall(require, "readhistory")
    if not ok_rh or not ReadHistory then return books end

    for _i, entry in ipairs(ReadHistory.hist or {}) do
        if entry.file then
            local title = entry.file:match("([^/]+)%.[^%.]+$") or entry.file
            table.insert(books, {
                title = title,
                authors = "",
                file = entry.file,
            })
        end
    end
    return books
end

--- Query the stats database, return a normalized-title → stats map.
function LocalBooks:_getStatsMap()
    local stats = {}
    local db = self:_openStatsDB()
    if not db then return stats end

    local ok, err = pcall(function()
        local stmt = db:prepare([[
            SELECT title, authors,
                   total_read_time, total_read_pages,
                   highlights, notes
            FROM book
        ]])
        if not stmt then return end
        for row in stmt:rows() do
            local key = self:normalizeTitle(row[1] or "")
            if key ~= "" then
                stats[key] = {
                    authors = row[2] or "",
                    total_read_time = tonumber(row[3]) or 0,
                    total_read_pages = tonumber(row[4]) or 0,
                    highlights = tonumber(row[5]) or 0,
                    notes = tonumber(row[6]) or 0,
                }
            end
        end
        stmt:close()
    end)

    db:close()
    if not ok then
        logger.warn("BookWyrm: stats DB error:", err)
    end
    return stats
end

function LocalBooks:_openStatsDB()
    local db_path = DataStorage:getSettingsDir() .. "/statistics.sqlite3"
    local ok, db = pcall(SQ3.open, db_path, "ro")
    if not ok or not db then return nil end
    return db
end

--- Match a BookWyrm book against local books. ISBN first, title fallback.
function LocalBooks:match(bw_book, local_index)
    if not bw_book or not local_index then return nil end

    -- Try ISBN-13
    if bw_book.isbn_13 then
        local isbn = bw_book.isbn_13:gsub("-", "")
        if local_index.by_isbn[isbn] then
            return local_index.by_isbn[isbn]
        end
    end

    -- Try ISBN-10
    if bw_book.isbn_10 then
        local isbn = bw_book.isbn_10:gsub("-", "")
        if local_index.by_isbn[isbn] then
            return local_index.by_isbn[isbn]
        end
    end

    -- Fallback: title matching
    local key = self:normalizeTitle(bw_book.title)
    if key ~= "" then
        -- Try exact match first, but only if file exists
        if local_index.by_title[key] then
            local entry = local_index.by_title[key]
            if not entry.file or entry.file_exists then
                return entry
            end
            logger.dbg("BookWyrm: exact match but file missing:", entry.file)
        end

        -- Substring match: BW key contained in local key or vice versa
        -- Prefer entries with valid file paths.
        -- Note: pairs() order is undefined, so when multiple titles match
        -- the substring, which one wins is nondeterministic.
        local best = nil
        for local_key, entry in pairs(local_index.by_title) do
            if local_key ~= key and (local_key:find(key, 1, true) or key:find(local_key, 1, true)) then
                if entry.file_exists then
                    best = entry
                    break
                elseif not best then
                    best = entry
                end
            end
        end
        if best then
            logger.dbg("BookWyrm: substring match for", bw_book.title, "→", best.title, "file:", best.file)
            return best
        end
    end

    -- Debug: log failed match
    logger.dbg("BookWyrm: no match for BW title:", bw_book.title, "→ key:", key,
               "isbn13:", bw_book.isbn_13, "isbn10:", bw_book.isbn_10)

    return nil
end

function LocalBooks:normalizeTitle(title)
    if not title then return "" end
    return title:lower():gsub("[^%w]", "")
end

function LocalBooks:formatTime(seconds)
    if not seconds or seconds <= 0 then return nil end
    local hours = math.floor(seconds / 3600)
    local mins = math.floor((seconds % 3600) / 60)
    if hours > 0 then
        return ("%dh %dm"):format(hours, mins)
    else
        return ("%dm"):format(mins)
    end
end

return LocalBooks
