local bit = require 'bit'
local ffi = require 'ffi'
local sizeof = ffi.sizeof
local tohex = bit.tohex

local byte = string.byte
local concat = table.concat

local Nibs = require './nibs.lua'
local nibs = Nibs.new()
local Ordered = require './ordered.lua'
local OrderedMap = Ordered.OrderedMap
local OrderedList = Ordered.OrderedList

local Zero = {id=0,name="Zero"}
local One = {id=1,name="One"}
local Two = {id=2,name="Two"}
local Three = "Three"
nibs.registerRef(0, Zero)
nibs.registerRef(1, One)
nibs.registerRef(2, Two)
nibs.registerRef(3, Three)

local tests = {
    -- ZigZag Integer
    0, "\x00",
    0x1, "\x02",
    0x10, "\x0c\x20",
    0x100, "\x0d\x00\x02",
    0x1000, "\x0d\x00\x20",
    0x10000, "\x0e\x00\x00\x02\x00",
    0x100000, "\x0e\x00\x00\x20\x00",
    0x1000000, "\x0e\x00\x00\x00\x02",
    0x10000000, "\x0e\x00\x00\x00\x20",
    0x100000000, "\x0f\x00\x00\x00\x00\x02\x00\x00\x00",
    0x1000000000, "\x0f\x00\x00\x00\x00\x20\x00\x00\x00",
    0x10000000000, "\x0f\x00\x00\x00\x00\x00\x02\x00\x00",
    0x100000000000, "\x0f\x00\x00\x00\x00\x00\x20\x00\x00",
    0x1000000000000, "\x0f\x00\x00\x00\x00\x00\x00\x02\x00",
    0x10000000000000, "\x0f\x00\x00\x00\x00\x00\x00\x20\x00",
    0x100000000000000, "\x0f\x00\x00\x00\x00\x00\x00\x00\x02",
    0x1000000000000000, "\x0f\x00\x00\x00\x00\x00\x00\x00\x20",
    -0x1, "\x01",
    -0x10, "\x0c\x1f",
    -0x100, "\x0d\xff\x01",
    -0x1000, "\x0d\xff\x1f",
    -0x10000, "\x0e\xff\xff\x01\x00",
    -0x100000, "\x0e\xff\xff\x1f\x00",
    -0x1000000, "\x0e\xff\xff\xff\x01",
    -0x10000000, "\x0e\xff\xff\xff\x1f",
    -0x100000000, "\x0f\xff\xff\xff\xff\x01\x00\x00\x00",
    -0x1000000000, "\x0f\xff\xff\xff\xff\x1f\x00\x00\x00",
    -0x10000000000, "\x0f\xff\xff\xff\xff\xff\x01\x00\x00",
    -0x100000000000, "\x0f\xff\xff\xff\xff\xff\x1f\x00\x00",
    -0x1000000000000, "\x0f\xff\xff\xff\xff\xff\xff\x01\x00",
    -0x10000000000000, "\x0f\xff\xff\xff\xff\xff\xff\x1f\x00",
    -0x100000000000000LL, "\x0f\xff\xff\xff\xff\xff\xff\xff\x01",
    -0x1000000000000000LL, "\x0f\xff\xff\xff\xff\xff\xff\xff\x1f",
    0x11, "\x0c\x22",
    0x101, "\x0d\x02\x02",
    0x1001, "\x0d\x02\x20",
    0x10001, "\x0e\x02\x00\x02\x00",
    0x100001, "\x0e\x02\x00\x20\x00",
    0x1000001, "\x0e\x02\x00\x00\x02",
    0x10000001, "\x0e\x02\x00\x00\x20",
    0x100000001, "\x0f\x02\x00\x00\x00\x02\x00\x00\x00",
    0x1000000001, "\x0f\x02\x00\x00\x00\x20\x00\x00\x00",
    0x10000000001, "\x0f\x02\x00\x00\x00\x00\x02\x00\x00",
    0x100000000001, "\x0f\x02\x00\x00\x00\x00\x20\x00\x00",
    0x1000000000001, "\x0f\x02\x00\x00\x00\x00\x00\x02\x00",
    0x10000000000001, "\x0f\x02\x00\x00\x00\x00\x00\x20\x00",
    0x100000000000001LL, "\x0f\x02\x00\x00\x00\x00\x00\x00\x02",
    0x1000000000000001LL, "\x0f\x02\x00\x00\x00\x00\x00\x00\x20",
    42, "\x0c\x54",
    500, "\x0d\xe8\x03",
    0xdedbeef, "\x0e\xde\x7d\xdb\x1b",
    0xdeadbeef, "\x0f\xde\x7d\x5b\xbd\x01\x00\x00\x00",
    0x20000000000000, "\x0f\x00\x00\x00\x00\x00\x00\x40\x00",
    0x123456789abcdef0LL, "\x0f\xe0\xbd\x79\x35\xf1\xac\x68\x24",
    -1, "\x01",
    -42, "\x0c\x53",
    -500, "\x0d\xe7\x03",
    -0xdedbeef, "\x0e\xdd\x7d\xdb\x1b",
    -0xdeadbeef, "\x0f\xdd\x7d\x5b\xbd\x01\x00\x00\x00",
    -0x123456789abcdef0LL, "\x0f\xdf\xbd\x79\x35\xf1\xac\x68\x24",
    -- Luajit version also treats cdata integers as integers
    ffi.new("uint8_t", 42), "\x0c\x54",
    ffi.new("int8_t", 42), "\x0c\x54",
    ffi.new("int8_t", -42), "\x0c\x53",
    ffi.new("uint16_t", 42), "\x0c\x54",
    ffi.new("int16_t", 42), "\x0c\x54",
    ffi.new("int16_t", -42), "\x0c\x53",
    ffi.new("uint32_t", 42), "\x0c\x54",
    ffi.new("int32_t", 42), "\x0c\x54",
    ffi.new("int32_t", -42), "\x0c\x53",
    ffi.new("uint64_t", 42), "\x0c\x54",
    ffi.new("int64_t", 42), "\x0c\x54",
    ffi.new("int64_t", -42), "\x0c\x53",

    -- Float
    math.pi, "\x1f\x18\x2d\x44\x54\xfb\x21\x09\x40",
    0/0, "\x1f\x00\x00\x00\x00\x00\x00\xf8\xff", -- luajit representation of NaN
    1/0, "\x1f\x00\x00\x00\x00\x00\x00\xf0\x7f", -- luajit representation of Inf
    -1/0, "\x1f\x00\x00\x00\x00\x00\x00\xf0\xff", -- luajit representation of -Inf
    ffi.new("double", math.pi), "\x1f\x18\x2d\x44\x54\xfb\x21\x09\x40",
    ffi.new("double", -math.pi), "\x1f\x18\x2d\x44\x54\xfb\x21\x09\xc0",
    ffi.new("float", math.pi), "\x1f\x00\x00\x00\x60\xfb\x21\x09\x40",
    ffi.new("float", -math.pi), "\x1f\x00\x00\x00\x60\xfb\x21\x09\xc0",

    -- Simple
    false, "\x20",
    true, "\x21",
    nil, "\x22",

    -- Ref
    Zero, "\x30",
    One, "\x31",
    Two, "\x32",
    Three, "\x33",

    -- Binary
    -- null terminated C string
    ffi.new("const char*", "Binary!"), "\x88Binary!\0",
    -- C byte array
    ffi.new("uint8_t[3]", {1,2,3}), "\x83\x01\x02\x03",
    -- C double array
    ffi.new("double[1]", {math.pi}), "\x88\x18\x2d\x44\x54\xfb\x21\x09\x40",
    -- String
    "Hello", "\x95Hello",
    -- Tuple
    {1,2,3}, "\xa3\x02\x04\x06",
    OrderedList.new(), "\xa0",
    -- Map
    {name="Tim"}, "\xb9\x94name\x93Tim",
    OrderedMap.new(), "\xb0",
    -- Complex (uses OrderedMap to preserve map order and nil value)
    { OrderedMap.new(10,100,20,50,true,false), OrderedMap.new("foo",nil) },
        "\xac\x11" .. -- Tuple(17)
            "\xba" .. -- Map(10)
                "\x0c\x14" .. -- Int(20) -> 10
                "\x0c\xc8" .. -- Int(200) -> 100
                "\x0c\x28" .. -- Int(40) -> 20
                "\x0c\x64" .. -- Int(100) -> 50
                "\x21" .. -- Simple(1) -> true
                "\x20" .. -- Simple(0) -> false
                "\xb5" .. -- Map(5)
                "\x93foo" .. -- String(3) "foo"
                "\x22", -- Simple(2) -> null
}

local function dump_string(str)
    local parts = {}
    for i = 1, #str do
        parts[i] = "\\x" .. tohex(byte(str, i),2)
    end
    return '"' .. concat(parts) .. '"'
end

local function equal(a,b)
    if ((a ~= a) and (b ~= b)) or a == b then return true end
    local kind = type(a)
    if kind == "cdata" and nibs.is(a) then
        kind = "table"
    end
    local kindb = type(b)
    if kindb == "cdata" and nibs.is(b) then
        kindb = "table"
    end
    if kind ~= kindb then return false end
    if kind == "cdata" then
        local len = sizeof(a)
        if len ~= sizeof(b) then return false end
        local abin = ffi.cast("const uint8_t*", a)
        local bbin = ffi.cast("const uint8_t*", b)
        for i = 0, len - 1 do
            if abin[i] ~= bbin[i] then return false end
        end
        return true
    end
    if kind == "table" then
        if #a ~= #b then return false end
        for k, v in pairs(a) do
            if not equal(v,b[k]) then return false end
        end
        for k, v in pairs(b) do
            if not equal(v,a[k]) then return false end
        end
        return true
    end
    if kind == "number" or kind == "string" or kind == "boolean" then
        return false
    end
    error("Unknown Type: " .. kind)
end

for i = 1, #tests, 2 do
    print()
    local input = tests[i]
    p("input", input)
    local expected = tests[i+1]
    local buf = nibs.encode(input)
    local str = ffi.string(buf, sizeof(buf))
    print("'expected'\t" .. dump_string(expected))
    print("'actual'\t" .. dump_string(str))
    assert(ffi.string(buf, sizeof(buf)) == expected)
    local decoded = nibs.decode(buf)
    p("decoded", decoded)
    assert(equal(decoded, input), "decode failed")
end
