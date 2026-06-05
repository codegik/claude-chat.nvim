local frame = require("claude-chat.ide.frame")
local bit = require("bit")

-- Encode a frame the way a client does: masked.
local function mask_encode(opcode, payload, mask)
  mask = mask or { 0x37, 0xfa, 0x21, 0x3d }
  local b1 = string.char(bit.bor(0x80, opcode))
  local n = #payload
  local header
  if n < 126 then
    header = b1 .. string.char(bit.bor(0x80, n))
  else
    header = b1 .. string.char(bit.bor(0x80, 126)) .. string.char(bit.rshift(n, 8), bit.band(n, 0xff))
  end
  local mk = string.char(mask[1], mask[2], mask[3], mask[4])
  local out = {}
  for i = 1, n do
    out[i] = string.char(bit.bxor(payload:byte(i), mask[((i - 1) % 4) + 1]))
  end
  return header .. mk .. table.concat(out)
end

describe("ide.frame", function()
  it("round-trips a short text frame (server style, unmasked)", function()
    local frames, rest = frame.decode(frame.encode(frame.OP_TEXT, "hello"))
    assert.equals(1, #frames)
    assert.equals("hello", frames[1].payload)
    assert.equals(frame.OP_TEXT, frames[1].opcode)
    assert.is_true(frames[1].fin)
    assert.equals("", rest)
  end)

  it("decodes a masked client frame", function()
    local frames = frame.decode(mask_encode(frame.OP_TEXT, "ping from client"))
    assert.equals("ping from client", frames[1].payload)
  end)

  it("handles 16-bit payload lengths", function()
    local big = string.rep("x", 1000)
    local frames = frame.decode(frame.encode(frame.OP_TEXT, big))
    assert.equals(big, frames[1].payload)
    local masked = frame.decode(mask_encode(frame.OP_TEXT, big))
    assert.equals(big, masked[1].payload)
  end)

  it("handles 64-bit payload lengths", function()
    local huge = string.rep("y", 70000)
    local frames = frame.decode(frame.encode(frame.OP_TEXT, huge))
    assert.equals(huge, frames[1].payload)
  end)

  it("buffers an incomplete frame until the rest arrives", function()
    local enc = frame.encode(frame.OP_TEXT, "hello")
    local frames, rest = frame.decode(enc:sub(1, 3))
    assert.equals(0, #frames)
    assert.equals(enc:sub(1, 3), rest)
    local frames2 = frame.decode(rest .. enc:sub(4))
    assert.equals("hello", frames2[1].payload)
  end)

  it("decodes two frames in one buffer", function()
    local buf = frame.encode(frame.OP_TEXT, "one") .. frame.encode(frame.OP_TEXT, "two")
    local frames = frame.decode(buf)
    assert.equals(2, #frames)
    assert.equals("one", frames[1].payload)
    assert.equals("two", frames[2].payload)
  end)

  it("flags ping and close opcodes", function()
    assert.equals(frame.OP_PING, frame.decode(frame.encode(frame.OP_PING, ""))[1].opcode)
    assert.equals(frame.OP_CLOSE, frame.decode(frame.encode(frame.OP_CLOSE, ""))[1].opcode)
  end)
end)
