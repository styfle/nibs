local Tibs = require 'tibs-types'
local NibLib = require 'nib-lib'

local bit = require 'bit'
local bor = bit.bor
local band = bit.band
local rshift = bit.rshift

local ffi = require 'ffi'
local I64 = ffi.typeof 'int64_t'

local byte = string.byte
local char = string.char
local sub = string.sub
local format = string.format

local concat = table.concat

-- Unique token used for parse errors
local Fail = { FAIL = true }
Tibs.Fail = Fail

-- Wrap parser implementation in collapsable block scope
-- Tibs.decode(json)
do

    -- Hoist declarations
    local nextToken, parseAny,
    parseNumber, parseRef, parseString, parseBytes,
    parseArray, parseObject, parseScope

    --- This is the main public interface.  Given a json string return
    --- the lua representation.  Array/Object/null semantics are preserved.
    ---@param json string
    ---@return boolean|string|number|table|nil parsed value
    ---@return string? error
    function Tibs.decode(json)
        assert(type(json) == "string", "JSON or Tibs string expected")
        local value, index = parseAny(json, 1)
        local b

        -- Make sure there is only whitespace after value,
        -- otherwise fail the parse.
        if value ~= Fail then
            b, index = nextToken(json, index)
            if b then value = Fail end
        end

        -- Return the value if it's still value.
        if value ~= Fail then
            return value
        end

        local row = 0
        local col = 0
        for line in string.gmatch(string.sub(json, 1, index - 1), "[^\r\n]*\r?\n?") do
            if #line > 0 then
                row = row + 1
                col = #line + 1
            end
        end

        -- Report parse error
        if index <= #json then
            return nil, format("Unexpected %q at index %d (row %d / col %d)",
                sub(json, index, index), index, row, col)
        end
        return nil, format("Unexpected EOS at index %d (row %d / col %d)", index, row, col)
    end

    ---Skip whitespace and get next byte
    ---@param json string
    ---@param index number
    ---@return number next_byte
    ---@return number new_index
    function nextToken(json, index)
        while true do
            local b = byte(json, index)
            if not (b == 9 or b == 10 or b == 13 or b == 32) then
                return b, index
            end
            index = index + 1
        end
    end

    function parseNumber(json, index)
        local b, start = nextToken(json, index)

        -- Optional leading `-`
        if b == 45 then -- `-`
            index = index + 1
            b = byte(json, index, index)
        end

        -- Integer part of number
        if b == 48 then -- `0`
            index = index + 1
            b = byte(json, index)
        elseif b and (b >= 49 and b <= 57) then -- `[1-9]`
            index = index + 1
            b = byte(json, index)
            while b and (b >= 48 and b <= 57) do -- `[0-9]*`
                index = index + 1
                b = byte(json, index)
            end
        else
            -- Must be zero or positive integer
            return Fail, index
        end

        -- optional decimal part of number
        if b == 46 then -- `.`
            index = index + 1
            b = byte(json, index)

            -- Can't stop here, must have at least one `[0-9]`.
            if not b or b < 48 or b > 57 then
                return Fail, index
            end

            while b and (b >= 48 and b <= 57) do -- `0-9`
                index = index + 1
                b = byte(json, index)
            end
        end

        -- Optional exponent part of number
        if b == 69 or b == 101 then -- `E` or `e`
            index = index + 1
            b = byte(json, index)

            -- Optional sign inside exponent
            if b == 43 or b == 45 then -- `+` or `-`
                index = index + 1
                b = byte(json, index)
            end

            -- Can't stop here, must have at least one `[0-9]`.
            if not b or b < 48 or b > 57 then
                return Fail, index
            end
            while b and (b >= 48 and b <= 57) do -- `0-9`
                index = index + 1
                b = byte(json, index)
            end
        end

        local text = sub(json, start, index - 1)
        local num
        if string.match(text, "^-?[0-9]+$") then
            local neg = false
            local big = I64(0)
            for i = 1, #text do
                if string.sub(text, i, i) == "-" then
                    neg = true
                else
                    big = big * 10 - (byte(text, i) - 48)
                end
            end
            if not neg then big = -big end
            if I64(tonumber(big)) == big then
                num = tonumber(big)
            else
                num = big
            end
        else
            num = tonumber(text)
        end

        return num, index
    end

    local stringEscapes = {
        [92] = char(92),
        [34] = char(34),
        [47] = char(47),
        [98] = char(8),
        [102] = char(12),
        [110] = char(10),
        [114] = char(13),
        [116] = char(9),
    }

    local highPair = nil
    local function utf8Encode(c)
        -- Encode surrogate pairs as a single utf8 codepoint
        if highPair then
            local lowPair = c
            c = ((highPair - 0xd800) * 0x400) + (lowPair - 0xdc00) + 0x10000
        elseif c >= 0xd800 and c <= 0xdfff then --surrogate pair
            highPair = c
            return nil, true
        end
        highPair = nil

        if c <= 0x7f then
            return char(c)
        elseif c <= 0x7ff then
            return char(
                bor(0xc0, rshift(c, 6)),
                bor(0x80, band(c, 0x3f))
            )
        elseif c <= 0xffff then
            return char(
                bor(0xe0, rshift(c, 12)),
                bor(0x80, band(rshift(c, 6), 0x3f)),
                bor(0x80, band(c, 0x3f))
            )
        elseif c <= 0x10ffff then
            return char(
                bor(0xf0, rshift(c, 18)),
                bor(0x80, band(rshift(c, 12), 0x3f)),
                bor(0x80, band(rshift(c, 6), 0x3f)),
                bor(0x80, band(c, 0x3f))
            )
        else
            error "Invalid codepoint"
        end
    end

    local function parseEscapedString(json, index)
        local b = byte(json, index)
        if b ~= 34 then -- `"`
            return Fail, index
        end
        index = index + 1
        b = byte(json, index)

        local first = index
        local parts = {}
        local i = 1
        local pairHalf
        while b ~= 34 do -- `"`
            if not b then return Fail, index end
            if b == 92 then -- `\`
                if index > first then
                    parts[i] = sub(json, first, index - 1)
                    i = i + 1
                end
                index = index + 1
                b = byte(json, index)
                if not b then return Fail, index end

                local e = stringEscapes[b]
                if e then
                    parts[i] = e
                    i = i + 1
                    index = index + 1
                    b = byte(json, index)
                    first = index
                elseif b == 117 then -- `u`
                    local d = 0
                    -- 4 required digits
                    for _ = 1, 4 do
                        index = index + 1
                        b = byte(json, index)
                        if not b then
                            return Fail, index
                        end
                        if b >= 48 and b <= 57 then
                            d = (d * 16) + (b - 48)
                        elseif b >= 97 and b <= 102 then
                            d = (d * 16) + (b - 87)
                        elseif b >= 65 and b <= 70 then
                            d = (d * 16) + (b - 55)
                        else
                            return Fail, index
                        end
                    end
                    local encoded
                    encoded, pairHalf = utf8Encode(d)
                    if encoded then
                        parts[i] = encoded
                        i = i + 1
                    end
                    index = index + 1
                    b = byte(json, index)
                    first = index
                end
            else
                index = index + 1
                b = byte(json, index)
            end
        end
        if index > first then
            parts[i] = sub(json, first, index - 1)
            i = i + 1
        end
        if pairHalf then
            parts[i] = "?"
        end
        return concat(parts), index + 1
    end

    function parseString(json, index)
        local b, start = nextToken(json, index)
        index = start
        if b ~= 34 then -- `"`
            return Fail, index
        end
        index = index + 1
        b = byte(json, index)

        while b ~= 34 do -- `"`
            if not b then return Fail, index end
            if b == 92 then -- `\`
                return parseEscapedString(json, start)
            else
                index = index + 1
                b = byte(json, index)
            end
        end
        return sub(json, start + 1, index - 1), index + 1
    end

    function parseBytes(json, index)
        local b
        b, index = nextToken(json, index)
        if b ~= 60 then -- `<`
            return Fail, index
        end
        index = index + 1
        local start = index

        b, index = nextToken(json, index)

        while b ~= 62 do -- `>`
            if not b
                or (b < 48 or b > 57) -- `0`-`9`
                and (b < 65 or b > 70) -- `A`-`F`
                and (b < 97 or b > 102) -- `a`-`f`
            then
                return Fail, index
            end
            index = index + 1
            b, index = nextToken(json, index)
        end
        local inner = sub(json, start, index - 1)
        local bytes = NibLib.hexStrToBuf(inner:gsub('[ \n\r\t]+', ''))
        return bytes, index + 1
    end

    function parseArray(json, index)
        local b
        -- Consume opening square bracket
        b, index = nextToken(json, index)
        if b ~= 91 then return Fail, index end -- `[`
        index = index + 1

        -- Consume indexed tag
        local indexed = false
        b, index = nextToken(json, index)
        if b == 35 then -- `#`
            indexed = true
            index = index + 1
        end

        local array = indexed and Tibs.Array.new() or Tibs.List.new()
        local i = 1
        while true do
            -- Read the next token
            b, index = nextToken(json, index)
            if not b then return Fail, index end

            -- Exit the loop if it's a closing square bracket
            if b == 93 then -- `]`
                index = index + 1
                break
            end

            -- Consume a comma if we're not on the first loop
            if i > 1 then
                if b ~= 44 then return Fail, index end -- `,`
                index = index + 1
            end

            b, index = nextToken(json, index)
            if not b then return Fail, index end

            -- Allow trailing commas by checking agin for closing brace
            if b == 93 then -- `]`
                index = index + 1
                break
            end


            -- Parse a single value and add to the array
            local value
            value, index = parseAny(json, index)
            if value == Fail then
                return Fail, index
            end
            array[i] = value
            i = i + 1
        end
        return array, index
    end

    function parseObject(json, index)
        local b
        -- Consume opening curly brace
        b, index = nextToken(json, index)
        if b ~= 123 then return Fail, index end -- `{`
        index = index + 1

        -- Consume indexed tag
        local indexed = false
        b, index = nextToken(json, index)
        if b == 35 then -- `#`
            indexed = true
            index = index + 1
        end

        local object = indexed and Tibs.Trie.new() or Tibs.Map.new()
        local i = 1
        while true do
            -- Read the next token
            b, index = nextToken(json, index)
            if not b then return Fail, index end

            -- Exit the loop if it's a closing curly brace
            if b == 125 then -- `}`
                index = index + 1
                break
            end

            -- Consume a comma if we're not on the first loop
            if i > 1 then
                if b ~= 44 then return Fail, index end -- `,`
                index = index + 1
            end

            b, index = nextToken(json, index)
            if not b then return Fail, index end

            -- Allow trailing commas by checking agin for closing brace
            if b == 125 then -- `}`
                index = index + 1
                break
            end

            -- Parse a single string as key
            local key
            key, index = parseAny(json, index)
            if key == Fail then
                return Fail, index
            end

            -- Consume the colon
            b, index = nextToken(json, index)
            if b ~= 58 then return Fail, index end -- `:`
            index = index + 1

            -- Parse a single value
            local value
            value, index = parseAny(json, index)
            if value == Fail then
                return Fail, index
            end

            -- Add the key/value pair to the object
            object[key] = value
            i = i + 1
        end
        return object, index
    end

    function parseScope(json, index)
        local b
        -- Consume opening paren brace
        b, index = nextToken(json, index)
        if b ~= 40 then return Fail, index end -- `(`
        index = index + 1

        -- Parse a single value as child
        local child
        child, index = parseAny(json, index)
        if child == Fail then
            return Fail, index
        end

        local scope = Tibs.List.new(child)
        local i = 1
        while true do
            -- Read the next token
            b, index = nextToken(json, index)
            if not b then return Fail, index end

            -- Exit the loop if it's a closing paren
            if b == 41 then -- `)`
                index = index + 1
                break
            end

            -- Consume a comma
            if b ~= 44 then return Fail, index end -- `,`
            index = index + 1

            local ref
            ref, index = parseAny(json, index)
            if ref == Fail then
                return Fail, index
            end
            i = i + 1
            scope[i] = ref

        end
        return Tibs.Scope.new(scope), index
    end

    function parseRef(json, index)
        local b
        -- Consume ampersand
        b, index = nextToken(json, index)
        if b ~= 38 then return Fail, index end -- `&`
        index = index + 1

        local idx
        idx, index = parseNumber(json, index)
        if not idx then return nil, index end
        return Tibs.Ref.new(idx), index
    end

    function parseAny(json, index)
        -- Exit if we run out of string to parse
        local b
        b, index = nextToken(json, index)
        if not b then return Fail, index end

        -- Parse based on first character
        if b == 123 then -- `{` `}`
            return parseObject(json, index)
        elseif b == 91 then -- `[` `]`
            return parseArray(json, index)
        elseif b == 40 then -- `(` `)`
            return parseScope(json, index)
        elseif b == 38 then -- `&`
            return parseRef(json, index)
        elseif b == 34 then -- `"`
            return parseString(json, index)
        elseif b == 60 then -- `<`
            return parseBytes(json, index)
        elseif b == 45 and sub(json, index, index + 3) == "-inf" then
            return -1 / 0, index + 4
        elseif b == 110 and sub(json, index, index + 2) == "nan" then
            return 0 / 0, index + 3
        elseif b == 105 and sub(json, index, index + 2) == "inf" then
            return 1 / 0, index + 3
        elseif b == 45 or (b >= 48 and b <= 57) then -- `-` or `0-9`
            return parseNumber(json, index)
        elseif b == 102 and sub(json, index, index + 4) == "false" then
            return false, index + 5
        elseif b == 116 and sub(json, index, index + 3) == "true" then
            return true, index + 4
        elseif b == 110 and sub(json, index, index + 3) == "null" then
            return nil, index + 4
        else
            return Fail, index
        end
    end

end

-- Wrap encoder implementation in collapsable block scope
-- Tibs.encode(val)
do
    local encode

    local stringEscapes = {
        [92] = 92, -- `\\`
        [34] = 34, -- `\"`
        [8] = 98, -- `\b`
        [12] = 102, -- `\f`
        [10] = 110, -- `\n`
        [13] = 114, -- `\r`
        [9] = 116, --`\t`
    }

    local function encodeString(str)
        local start = 1
        local parts = {}
        local i = 1
        local len = #str
        for index = start, len do
            local escape = stringEscapes[byte(str, index)]
            if escape then
                if index > start then
                    parts[i] = sub(str, start, index - 1)
                    i = i + 1
                end
                parts[i] = char(92, escape)
                i = i + 1
                start = index + 1
            end
        end
        if len >= start then
            parts[i] = sub(str, start, len)
        end
        return '"' .. concat(parts) .. '"'
    end

    local function encodeArray(arr, tag)
        local parts = {}
        for i, v in ipairs(arr) do
            parts[i] = encode(v)
        end
        return "[" .. tag .. concat(parts, ",") .. "]"
    end

    local function encodeObject(obj, tag)
        local parts = {}
        local i = 1
        for k, v in pairs(obj) do
            parts[i] = encode(k) .. ':' .. encode(v)
            i = i + 1
        end
        return "{" .. tag .. concat(parts, ",") .. "}"
    end

    local reentered = nil
    function Tibs.encode(val)

        local typ = type(val)
        if typ == 'nil' then
            return "null"
        elseif typ == 'boolean' then
            return val and 'true' or 'false'
        elseif typ == 'string' then
            return encodeString(val)
        elseif typ == 'number' then
            return tostring(val)
        elseif typ == 'table' then

            local mt = getmetatable(val)
            if mt and reentered ~= val and mt.__tojson then
                reentered = val
                local json = mt.__tojson(val, Tibs.encode)
                reentered = nil
                return json
            end
            local tag = mt and mt.__is_indexed and "#" or ""
            if NibLib.isArrayLike(val) then
                return encodeArray(val, tag)
            else
                return encodeObject(val, tag)
            end
        elseif typ == 'cdata' then
            if NibLib.isInteger(val) or NibLib.isFloat(val) then
                -- Treat cdata integers and floats as numbers
                return tostring(val)
            end
            local str = '<' .. NibLib.bufToHexStr(val) .. '>'
            return str
        else
            error("Cannot serialize " .. typ)
        end
    end

    encode = Tibs.encode
end

return Tibs
