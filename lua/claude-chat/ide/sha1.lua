-- Minimal SHA-1, returning the raw 20-byte digest. Needed only for the
-- WebSocket handshake (Sec-WebSocket-Accept). Uses LuaJIT's bit library.
local bit = require("bit")
local band, bor, bxor, bnot = bit.band, bit.bor, bit.bxor, bit.bnot
local lshift, rshift, rol = bit.lshift, bit.rshift, bit.rol

local M = {}

local function u32be(n)
  return string.char(
    band(rshift(n, 24), 0xff),
    band(rshift(n, 16), 0xff),
    band(rshift(n, 8), 0xff),
    band(n, 0xff)
  )
end

-- Returns the 20-byte binary SHA-1 digest of `msg`.
function M.binary(msg)
  local h0, h1, h2, h3, h4 = 0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0

  local len = #msg
  msg = msg .. "\128"
  while (#msg % 64) ~= 56 do
    msg = msg .. "\0"
  end
  local bitlen = len * 8
  msg = msg .. u32be(math.floor(bitlen / 2 ^ 32)) .. u32be(bitlen % 2 ^ 32)

  for chunk = 1, #msg, 64 do
    local w = {}
    for i = 0, 15 do
      local b = chunk + i * 4
      w[i] = bor(lshift(msg:byte(b), 24), lshift(msg:byte(b + 1), 16), lshift(msg:byte(b + 2), 8), msg:byte(b + 3))
    end
    for i = 16, 79 do
      w[i] = rol(bxor(w[i - 3], w[i - 8], w[i - 14], w[i - 16]), 1)
    end

    local a, b, c, d, e = h0, h1, h2, h3, h4
    for i = 0, 79 do
      local f, k
      if i < 20 then
        f = bor(band(b, c), band(bnot(b), d))
        k = 0x5A827999
      elseif i < 40 then
        f = bxor(b, c, d)
        k = 0x6ED9EBA1
      elseif i < 60 then
        f = bor(bor(band(b, c), band(b, d)), band(c, d))
        k = 0x8F1BBCDC
      else
        f = bxor(b, c, d)
        k = 0xCA62C1D6
      end
      local temp = band(rol(a, 5) + f + e + k + w[i], 0xffffffff)
      e, d, c, b, a = d, c, rol(b, 30), a, temp
    end

    h0 = band(h0 + a, 0xffffffff)
    h1 = band(h1 + b, 0xffffffff)
    h2 = band(h2 + c, 0xffffffff)
    h3 = band(h3 + d, 0xffffffff)
    h4 = band(h4 + e, 0xffffffff)
  end

  return u32be(h0) .. u32be(h1) .. u32be(h2) .. u32be(h3) .. u32be(h4)
end

return M
