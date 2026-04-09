-- Minimal stubs for KOReader modules so we can require plugin files
-- outside the KOReader runtime.

-- logger: swallow all calls
package.loaded["logger"] = setmetatable({}, {
    __index = function() return function() end end,
})

-- datastorage
package.loaded["datastorage"] = {
    getSettingsDir = function() return "/tmp" end,
}

-- json: use dkjson (installed with busted)
package.loaded["json"] = require("dkjson")

-- sqlite: stub out so localbooks loads without a real DB
package.loaded["lua-ljsqlite3/init"] = {
    open = function() return nil end,
}

-- ssl.https / socket.http / ltn12: stub for bookwyrmclient
package.loaded["ssl.https"] = { request = function() return nil, 0, {} end }
package.loaded["socket.http"] = { request = function() return nil, 0, {} end }
package.loaded["ltn12"] = { sink = { table = function() return function() end end } }
