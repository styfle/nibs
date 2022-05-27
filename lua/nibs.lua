--[[lit-meta
    name = "creationix/nibs"
    version = "1.1.0"
    homepage = "https://github.com/creationix/nibs"
    description = "An implementation of nibs serialization format for luajit."
    tags = {"nibs","serialization","jit"}
    license = "MIT"
    author = { name = "Tim Caswell" }
]]
local bit = require 'bit'
local rshift = bit.rshift
local band = bit.band
local lshift = bit.lshift
local bor = bit.bor
local bxor = bit.bxor

local ffi = require 'ffi'
local sizeof = ffi.sizeof
local copy = ffi.copy
local ffi_string = ffi.string
local cast = ffi.cast
local istype = ffi.istype
local metatype = ffi.metatype

local insert = table.insert

local U8 = ffi.typeof 'uint8_t'
local U16 = ffi.typeof 'uint16_t'
local U32 = ffi.typeof 'uint32_t'
local U64 = ffi.typeof 'uint64_t'
local I8 = ffi.typeof 'int8_t'
local I16 = ffi.typeof 'int16_t'
local I32 = ffi.typeof 'int32_t'
local I64 = ffi.typeof 'int64_t'
local F32 = ffi.typeof 'float'
local F64 = ffi.typeof 'double'

ffi.cdef [[struct NibsTuple { const uint8_t* first; const uint8_t* last; }]]
ffi.cdef [[struct NibsMap { const uint8_t* first; const uint8_t* last; }]]
local StructNibsTuple = ffi.typeof 'struct NibsTuple'
local StructNibsMap = ffi.typeof 'struct NibsMap'
local Slice = ffi.typeof 'uint8_t[?]'

local U8Ptr = ffi.typeof 'uint8_t*'
local U16Ptr = ffi.typeof 'uint16_t*'
local U32Ptr = ffi.typeof 'uint32_t*'
local U64Ptr = ffi.typeof 'uint64_t*'

local U16Box = ffi.typeof 'uint16_t[1]'
local U32Box = ffi.typeof 'uint32_t[1]'
local U64Box = ffi.typeof 'uint64_t[1]'

local int_types = { U8, U16, U32, U64, I8, I16, I32, I64 }
local float_types = { F32, F64 }

-- Toplevel type tags
local INT = 0
local FLOAT = 1
local SIMPLE = 2
local REF = 3
local TAG = 7
local BYTE = 8
local STRING = 9
local TUPLE = 10
local MAP = 11
local ARRAY = 12
-- Simple subtype tags
local FALSE = 0
local TRUE = 1
local NULL = 2

local function is_int_type(val)
    for _, typ in ipairs(int_types) do
        if istype(typ, val) then return true end
    end
    return false
end

local function is_float_type(val)
    for _, typ in ipairs(float_types) do
        if istype(typ, val) then return true end
    end
    return false
end

local converter = ffi.new 'union {double f;uint64_t i;}'
local function encode_float(val)
    converter.f = val
    return converter.i
end

local function decode_float(val)
    converter.i = val
    return converter.f
end

local function decode_simple(big)
    if big == FALSE then
        return false
    elseif big == TRUE then
        return true
    elseif big == NULL then
        return nil
    end
    error(string.format("Invalid simple type %d", big))
end

local function tonumberMaybe(n)
    local nn = tonumber(n)
    return nn == n and nn or n
end

---Convert a nibs big from zigzag to I64
---@param big integer
---@return integer
local function decode_zigzag(big)
    local i = I64(big)
    return tonumberMaybe(bxor(rshift(i, 1), -band(i, 1)))
end

---@param num integer
---@return integer
local function encode_zigzag(num)
    return num < 0 and num * -2 - 1 or num * 2
end

---@param ptr cdata
---@return integer
---@return integer
---@return integer
local function decode_pair(ptr)
    local head = ptr[0]
    local little = rshift(head, 4)
    local big = band(head, 0xf)
    if big == 0xc then
        return 2, little, ptr[1]
    elseif big == 0xd then
        return 3, little, cast(U16Ptr, ptr + 1)[0]
    elseif big == 0xe then
        return 5, little, cast(U32Ptr, ptr + 1)[0]
    elseif big == 0xf then
        return 9, little, cast(U64Ptr, ptr + 1)[0]
    else
        return 1, little, big
    end
end

local function skip(ptr)
    local offset, little, big = decode_pair(ptr)
    if little <= 5 then -- skip pair for small types
        return ptr + offset
    elseif little >= 8 then -- skip body for big types
        return ptr + offset + big
    elseif little == TAG then -- recurse for tags
        return skip(ptr + offset)
    else -- error for unknown types
        error('Unexpected nibs type: ' .. little)
    end
end

---@type table
---@return boolean
local function is_tuple(val)
    local i = 1
    for key in pairs(val) do
        if key ~= i then return false end
        i = i + 1
    end
    return true
end

local function encode_pair(small, big)
    local pair = lshift(small, 4)
    if big < 0xc then
        return 1, tonumber(bor(pair, big))
    elseif big < 0x100 then
        return 2, { bor(pair, 12), tonumber(big) }
    elseif big < 0x10000 then
        return 3, { bor(pair, 13), U16Box { big } }
    elseif big < 0x100000000ULL then
        return 5, { bor(pair, 14), U32Box { big } }
    else
        return 9, { bor(pair, 15), U64Box { big } }
    end
end

local Nibs = {}

function Nibs.new()

    local NibsTuple = {}
    local NibsMap = {}

    local function decode(ptr)
        ptr = cast(U8Ptr, ptr)
        local offset, little, big = decode_pair(ptr)
        if little == INT then
            return decode_zigzag(big), offset
        elseif little == FLOAT then
            return decode_float(big), offset
        elseif little == SIMPLE then
            return decode_simple(big), offset
        elseif little == BYTE then
            local slice = Slice(big)
            copy(slice, ptr + offset, big)
            return slice, offset + big
        elseif little == STRING then
            return ffi_string(ptr + offset, big), offset + big
        elseif little == TUPLE then
            return NibsTuple.new(ptr + offset, big), offset + big
        elseif little == MAP then
            return NibsMap.new(ptr + offset, big), offset + big
        else
            error('Unexpected nibs type: ' .. little)
        end
    end

    function NibsTuple.new(ptr, len) return StructNibsTuple { ptr, ptr + len } end

    function NibsTuple:__len()
        local current = self.first
        local count = 0
        while current < self.last do
            current = skip(current)
            count = count + 1
        end
        return count
    end

    function NibsTuple:__index(index)
        local current = self.first
        while current < self.last do
            index = index - 1
            if index == 0 then return decode(current) end
            current = skip(current)
        end
    end

    function NibsTuple:__ipairs()
        local current = self.first
        local i = 0
        return function()
            if current < self.last then
                local val, size = decode(current)
                current = current + size
                i = i + 1
                return i, val
            end
        end
    end

    NibsTuple.__pairs = NibsTuple.__ipairs

    function NibsMap.new(ptr, len)
        return setmetatable({
            __nibs_ptr = ptr,
            __nibs_len = len,
        }, NibsMap)
    end

    function NibsMap.__len() return 0 end

    function NibsMap.__ipairs() return function() end end

    function NibsMap:__pairs()
        local current = self.__nibs_ptr
        local last = current + self.__nibs_len
        return function()
            if current >= last then return end
            local key, value, size
            key, size = decode(current)
            current = current + size
            if current >= last then return end
            value, size = decode(current)
            current = current + size
            return key, value
        end
    end

    function NibsMap:__index(index)
        local current = self.__nibs_ptr
        local last = current + self.__nibs_len
        while current < last do
            local key, size = decode(current)
            current = current + size
            if current >= last then return end

            if key == index then return (decode(current)) end
            current = skip(current)
        end
    end

    local encode_any

    local function encode_tuple(tuple)
        local total = 0
        local body = {}
        for i = 1, #tuple do
            local size, entry = encode_any(tuple[i])
            insert(body, entry)
            total = total + size
        end
        local size, head = encode_pair(TUPLE, total)
        return size + total, { head, body }
    end

    local function encode_map(map)
        local total = 0
        local body = {}
        for k, v in pairs(map) do
            local size, entry = encode_any(k)
            insert(body, entry)
            total = total + size
            size, entry = encode_any(v)
            insert(body, entry)
            total = total + size
        end
        local size, head = encode_pair(MAP, total)
        return size + total, { head, body }
    end

    ---@param val any
    function encode_any(val)
        local kind = type(val)
        if is_int_type(val) then
            return encode_pair(INT, encode_zigzag(val))
        end
        if kind == 'number' then
            if val % 1 == 0 then
                return encode_pair(INT, encode_zigzag(val))
            else
                return encode_pair(FLOAT, encode_float(val)) -- Floating Point
            end
        elseif kind == 'boolean' then
            return encode_pair(SIMPLE, val and TRUE or FALSE) -- Simple true/false
        elseif kind == 'nil' then
            return encode_pair(SIMPLE, NULL) -- Simple nil
        elseif kind == 'cdata' then
            if is_int_type(val) then
                return encode_pair(INT, encode_zigzag(val)) -- Integer
            elseif is_float_type(val) then
                return encode_pair(FLOAT, encode_float(val)) -- Floating Point
            end
            local len = sizeof(val)
            local size, head = encode_pair(BYTE, len)
            return size + len, { head, val }
        elseif kind == 'string' then
            local len = #val
            local size, head = encode_pair(STRING, len)
            return size + len, { head, val }
        elseif kind == 'table' then
            if is_tuple(val) then
                return encode_tuple(val)
            else
                return encode_map(val)
            end
        else
            error('Unsupported value type: ' .. kind)
        end
    end

    local function encode(val)
        local i = 0
        local size, data = encode_any(val)
        local buf = Slice(size)
        local function write(d)
            local kind = type(d)
            if kind == 'number' then
                buf[i] = d
                i = i + 1
            elseif kind == 'cdata' then
                local len = sizeof(d)
                copy(buf + i, d, len)
                i = i + len
            elseif kind == 'string' then
                copy(buf + i, d)
                i = i + #d
            elseif kind == 'table' then
                for j = 1, #d do write(d[j]) end
            end
        end

        write(data)
        assert(size == i)
        return buf
    end

    metatype(StructNibsTuple, NibsTuple)
    metatype(StructNibsMap, NibsMap)

    --- Returns true if a value is a virtual nibs container.
    local function is(val) return istype(StructNibsTuple, val) or istype(StructNibsMap, val) end

    return {
        encode = encode,
        decode = decode,
        is = is,
    }

end

return Nibs
