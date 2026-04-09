require("spec.stub")
local BookWyrmClient = require("bookwyrmclient")

describe("BookWyrmClient", function()

    describe("parseBook", function()
        it("parses a full Edition object", function()
            local ap = {
                type = "Edition",
                title = "Educated",
                subtitle = "A Memoir",
                authors = { "https://bookwyrm.social/author/123" },
                isbn13 = "9780143127550",
                isbn10 = "0143127551",
                cover = { url = "https://example.com/cover.jpg" },
                physicalFormat = "Paperback",
                publishedDate = "2018-02-20",
                id = "https://bookwyrm.social/book/456",
                openlibraryKey = "OL12345W",
            }
            local book = BookWyrmClient:parseBook(ap)
            assert.is_not_nil(book)
            assert.are.equal("Educated", book.title)
            assert.are.equal("A Memoir", book.subtitle)
            assert.are.equal("9780143127550", book.isbn_13)
            assert.are.equal("0143127551", book.isbn_10)
            assert.are.equal("Paperback", book.format)
            assert.are.equal("2018-02-20", book.published)
            assert.are.equal("https://example.com/cover.jpg", book.cover_url)
            assert.are.equal(1, #book.author_urls)
            assert.is_nil(book.authors) -- resolved lazily
        end)

        it("uses 'Unknown' for missing title", function()
            local book = BookWyrmClient:parseBook({ type = "Edition" })
            assert.are.equal("Unknown", book.title)
        end)

        it("sets subtitle to nil when empty string", function()
            local book = BookWyrmClient:parseBook({ type = "Edition", title = "Test", subtitle = "" })
            assert.is_nil(book.subtitle)
        end)

        it("returns nil for non-Edition type", function()
            assert.is_nil(BookWyrmClient:parseBook({ type = "Work", title = "Test" }))
        end)

        it("returns nil for nil input", function()
            assert.is_nil(BookWyrmClient:parseBook(nil))
        end)

        it("handles missing optional fields", function()
            local book = BookWyrmClient:parseBook({ type = "Edition", title = "Minimal" })
            assert.are.equal("Minimal", book.title)
            assert.is_nil(book.isbn_13)
            assert.is_nil(book.isbn_10)
            assert.is_nil(book.cover_url)
            assert.is_nil(book.format)
            assert.is_nil(book.published)
        end)

        it("handles cover without url field", function()
            local book = BookWyrmClient:parseBook({ type = "Edition", title = "Test", cover = {} })
            assert.is_nil(book.cover_url)
        end)
    end)

    describe("resolveAuthors", function()
        it("returns empty string for nil", function()
            local client = BookWyrmClient:new()
            assert.are.equal("", client:resolveAuthors(nil))
        end)

        it("returns empty string for empty list", function()
            local client = BookWyrmClient:new()
            assert.are.equal("", client:resolveAuthors({}))
        end)

        it("handles inline author objects", function()
            local client = BookWyrmClient:new()
            local result = client:resolveAuthors({
                { name = "Craig Johnson" },
                { name = "Margaret Atwood" },
            })
            assert.are.equal("Craig Johnson, Margaret Atwood", result)
        end)
    end)
end)
