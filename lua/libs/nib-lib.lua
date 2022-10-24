local bit = require 'bit'
local rshift = bit.rshift
local lshift = bit.lshift
local band = bit.band
local bor = bit.bor

local byte = string.byte

local ffi = require 'ffi'
local new = ffi.new
local cast = ffi.cast
local sizeof = ffi.sizeof
local ffi_string = ffi.string
local Slice8 = ffi.typeof 'uint8_t[?]'
local U8Ptr = ffi.typeof 'uint8_t*'

local NibLib = {}

--- Returns true if a table should be treated like an array (ipairs/length/etc)
--- This uses the __is_array_like metaproperty if it exists, otherwise, it
--- iterates over the pairs keys checking if they look like an array (1...n)
---@param val table
---@return boolean is_array_like
function NibLib.isArrayLike(val)
    local mt = getmetatable(val)
    if mt and mt.__is_array_like ~= nil then
        return mt.__is_array_like
    end
    local i = 1
    for key in pairs(val) do
        if key ~= i then return false end
        i = i + 1
    end
    return true
end

--- Convert integer to ascii code for hex digit
--- Assumes input is valid number (0-15)
---@param num integer numerical value (0-15)
---@return integer code ascii hex digit [0-9a-f]
local function tohex(num)
    return num + (num <= 9 and 0x30 or 0x57)
end

--- Convert ascii hex digit to integer
--- Assumes input is valid character [0-9a-f]
---@param code integer ascii code for hex digit
---@return integer num value of hex digit (0-15)
local function fromhex(code)
    return code - (code >= 0x61 and 0x57 or 0x30)
end

---Turn any buffer into a hex encoded binary buffer
---@param str string
---@return ffi.cdata* hex
function NibLib.strToHexBuf(str)
    local len = #str * 2
    local buf = new(Slice8, len)
    for i = 1, #str do
        local b = byte(str, i)
        buf[i * 2 - 2] = tohex(rshift(b, 4))
        buf[i * 2 - 1] = tohex(band(b, 15))
    end
    return buf
end

---Turn any lua string into a hex encoded binary buffer
---@param str string
---@return string hex
function NibLib.strToHexStr(str)
    local buf = NibLib.strToHexBuf(str)
    local hex = ffi_string(buf, sizeof(buf))
    return hex
end

---Turn any buffer into a hex encoded binary buffer
---@param dat ffi.cdata*
---@return ffi.cdata* hex
function NibLib.bufToHexBuf(dat)
    local size = sizeof(dat)
    dat = cast(U8Ptr, dat) -- input can be any cdata, not just slice8
    local buf = new(Slice8, size * 2)
    for i = 0, size - 1 do
        local b = dat[i]
        buf[i * 2] = tohex(rshift(b, 4))
        buf[i * 2 + 1] = tohex(band(b, 15))
    end
    return buf
end

---Turn any buffer into a hex encoded binary string
---@param dat ffi.cdata*
---@return string hex
function NibLib.bufToHexStr(dat)
    local buf = NibLib.bufToHexBuf(dat)
    local hex = ffi_string(buf, sizeof(buf))
    return hex
end

--- Decode a hex encoded string into a binary buffer
---@param hex string
---@return ffi.cdata* buf
function NibLib.hexStrToBuf(hex)
    local len = #hex / 2
    local buf = new(Slice8, len)
    for i = 0, len - 1 do
        buf[i] = bor(
            lshift(fromhex(byte(hex, i * 2 + 1)), 4),
            fromhex(byte(hex, i * 2 + 2))
        )
    end
    return buf
end

--- Decode a hex encoded string into a raw string
---@param hex string
---@return string str
function NibLib.hexStrToStr(hex)
    local buf = NibLib.hexStrToBuf(hex)
    return ffi_string(buf, sizeof(buf))
end

--- Decode a hex encoded buffer into a binary buffer
---@param hex ffi.cdata*
---@return ffi.cdata* buf
function NibLib.hexBufToBuf(hex)
    local len = sizeof(hex) / 2
    hex = cast(U8Ptr, hex) -- input can be any cdata, not just slice8
    local buf = new(Slice8, len)
    for i = 0, len - 1 do
        buf[i] = bor(
            lshift(fromhex(hex[i * 2]), 4),
            fromhex(hex[i * 2 + 1])
        )
    end
    return buf
end

--- Decode a hex encoded buffer into a raw string
---@param hex ffi.cdata*
---@return string str
function NibLib.hexBufToStr(hex)
    local buf = NibLib.hexBufToBuf(hex)
    return ffi_string(buf, sizeof(buf))
end

function NibLib.strToBuf(str)
    return new(Slice8, #str, str)
end

function NibLib.bufToStr(buf)
    return ffi_string(buf, sizeof(buf))
end

return NibLib
