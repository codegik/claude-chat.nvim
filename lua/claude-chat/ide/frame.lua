-- WebSocket (RFC 6455) frame encode/decode. Server frames are unmasked;
-- client frames are masked. Handles 7/16/64-bit payload lengths.
local bit = require("bit")
local band, bor, bxor, lshift, rshift = bit.band, bit.bor, bit.bxor, bit.lshift, bit.rshift

local M = {}

M.OP_CONT = 0x0
M.OP_TEXT = 0x1
M.OP_BIN = 0x2
M.OP_CLOSE = 0x8
M.OP_PING = 0x9
M.OP_PONG = 0xA

-- Encode a single (final) frame for sending to the client. Not masked.
function M.encode(opcode, payload)
  payload = payload or ""
  local b1 = string.char(bor(0x80, opcode))
  local len = #payload
  local header
  if len < 126 then
    header = b1 .. string.char(len)
  elseif len < 65536 then
    header = b1 .. string.char(126) .. string.char(band(rshift(len, 8), 0xff), band(len, 0xff))
  else
    local bytes = {}
    local n = len
    for i = 8, 1, -1 do
      bytes[i] = string.char(n % 256)
      n = math.floor(n / 256)
    end
    header = b1 .. string.char(127) .. table.concat(bytes)
  end
  return header .. payload
end

-- Decode as many complete frames as `buf` contains.
-- Returns: list of { fin, opcode, payload }, and the unconsumed remainder.
function M.decode(buf)
  local frames = {}
  while true do
    if #buf < 2 then
      break
    end
    local b1, b2 = buf:byte(1), buf:byte(2)
    local fin = band(b1, 0x80) ~= 0
    local opcode = band(b1, 0x0f)
    local masked = band(b2, 0x80) ~= 0
    local len = band(b2, 0x7f)
    local offset = 2

    if len == 126 then
      if #buf < 4 then
        break
      end
      len = buf:byte(3) * 256 + buf:byte(4)
      offset = 4
    elseif len == 127 then
      if #buf < 10 then
        break
      end
      len = 0
      for i = 3, 10 do
        len = len * 256 + buf:byte(i)
      end
      offset = 10
    end

    local mask
    if masked then
      if #buf < offset + 4 then
        break
      end
      mask = { buf:byte(offset + 1), buf:byte(offset + 2), buf:byte(offset + 3), buf:byte(offset + 4) }
      offset = offset + 4
    end

    if #buf < offset + len then
      break
    end

    local payload = buf:sub(offset + 1, offset + len)
    if masked and len > 0 then
      local out = {}
      for i = 1, len do
        out[i] = string.char(bxor(payload:byte(i), mask[((i - 1) % 4) + 1]))
      end
      payload = table.concat(out)
    end

    buf = buf:sub(offset + len + 1)
    frames[#frames + 1] = { fin = fin, opcode = opcode, payload = payload }
  end
  return frames, buf
end

return M
