require("spec.stub")
local LocalBooks = require("localbooks")

describe("LocalBooks", function()

    describe("extractISBN", function()
        it("extracts a bare ISBN-13", function()
            assert.are.equal("9781436272025", LocalBooks:extractISBN("9781436272025"))
        end)

        it("extracts ISBN-13 with dashes", function()
            assert.are.equal("9781436272025", LocalBooks:extractISBN("978-1-4362-7202-5"))
        end)

        it("extracts urn:isbn: prefix", function()
            assert.are.equal("9781436272025", LocalBooks:extractISBN("urn:isbn:9781436272025"))
        end)

        it("extracts isbn: prefix", function()
            assert.are.equal("9781436272025", LocalBooks:extractISBN("isbn:9781436272025"))
        end)

        it("extracts a bare ISBN-10", function()
            assert.are.equal("0316769487", LocalBooks:extractISBN("0316769487"))
        end)

        it("extracts ISBN-10 with dashes", function()
            assert.are.equal("0316769487", LocalBooks:extractISBN("0-316-76948-7"))
        end)

        it("handles ISBN-10 with X check digit", function()
            assert.are.equal("080442957X", LocalBooks:extractISBN("080442957X"))
        end)

        it("extracts ISBN embedded in a longer string", function()
            assert.are.equal("9780143127550", LocalBooks:extractISBN("calibre:id:42 isbn:9780143127550 other"))
        end)

        it("returns nil for a Calibre UUID", function()
            assert.is_nil(LocalBooks:extractISBN("urn:uuid:a1b2c3d4-e5f6-7890-abcd-ef1234567890"))
        end)

        it("returns nil for empty string", function()
            assert.is_nil(LocalBooks:extractISBN(""))
        end)

        it("returns nil for nil", function()
            assert.is_nil(LocalBooks:extractISBN(nil))
        end)

        it("returns nil for short numbers", function()
            assert.is_nil(LocalBooks:extractISBN("12345"))
        end)
    end)

    describe("normalizeTitle", function()
        it("lowercases and strips non-alphanumeric", function()
            assert.are.equal("deathwithoutcompany", LocalBooks:normalizeTitle("Death Without Company"))
        end)

        it("strips punctuation", function()
            assert.are.equal("thebeekeepersapprentice", LocalBooks:normalizeTitle("The Beekeeper's Apprentice"))
        end)

        it("handles series prefix format", function()
            local normalized = LocalBooks:normalizeTitle("Walt Longmire Mysteries - 02 - Death Without Company: A Longmire Mystery")
            assert.are.equal("waltlongmiremysteries02deathwithoutcompanyalongmiremystery", normalized)
        end)

        it("returns empty for nil", function()
            assert.are.equal("", LocalBooks:normalizeTitle(nil))
        end)

        it("returns empty for empty string", function()
            assert.are.equal("", LocalBooks:normalizeTitle(""))
        end)

        it("returns empty for only punctuation", function()
            assert.are.equal("", LocalBooks:normalizeTitle("---"))
        end)
    end)

    describe("formatTime", function()
        it("formats hours and minutes", function()
            assert.are.equal("2h 13m", LocalBooks:formatTime(7980))
        end)

        it("formats minutes only when under an hour", function()
            assert.are.equal("45m", LocalBooks:formatTime(2700))
        end)

        it("formats exactly one hour", function()
            assert.are.equal("1h 0m", LocalBooks:formatTime(3600))
        end)

        it("returns nil for zero", function()
            assert.is_nil(LocalBooks:formatTime(0))
        end)

        it("returns nil for negative", function()
            assert.is_nil(LocalBooks:formatTime(-100))
        end)

        it("returns nil for nil", function()
            assert.is_nil(LocalBooks:formatTime(nil))
        end)
    end)

    describe("match", function()
        local index

        before_each(function()
            index = {
                by_isbn = {
                    ["9780143127550"] = { title = "Educated", file = "/books/educated.epub", file_exists = true },
                },
                by_title = {
                    ["educated"] = { title = "Educated", file = "/books/educated.epub", file_exists = true },
                    ["waltlongmiremysteries02deathwithoutcompanyalongmiremystery"] = {
                        title = "Walt Longmire Mysteries - 02 - Death Without Company",
                        file = "/books/death.epub",
                        file_exists = true,
                    },
                },
            }
        end)

        it("matches by ISBN-13", function()
            local bw_book = { title = "Educated", isbn_13 = "9780143127550" }
            local result = LocalBooks:match(bw_book, index)
            assert.is_not_nil(result)
            assert.are.equal("Educated", result.title)
        end)

        it("matches by exact normalized title", function()
            local bw_book = { title = "Educated" }
            local result = LocalBooks:match(bw_book, index)
            assert.is_not_nil(result)
            assert.are.equal("Educated", result.title)
        end)

        it("matches by substring (BW title contained in local title)", function()
            local bw_book = { title = "Death Without Company" }
            local result = LocalBooks:match(bw_book, index)
            assert.is_not_nil(result)
            assert.is_truthy(result.title:find("Death Without Company"))
        end)

        it("returns nil when no match", function()
            local bw_book = { title = "Nonexistent Book" }
            assert.is_nil(LocalBooks:match(bw_book, index))
        end)

        it("returns nil for nil book", function()
            assert.is_nil(LocalBooks:match(nil, index))
        end)

        it("returns nil for nil index", function()
            assert.is_nil(LocalBooks:match({ title = "Test" }, nil))
        end)
    end)
end)
