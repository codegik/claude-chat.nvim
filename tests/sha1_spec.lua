local sha1 = require("claude-chat.ide.sha1")

local function hex(s)
  return (s:gsub(".", function(c)
    return string.format("%02x", c:byte())
  end))
end

describe("ide.sha1", function()
  it("matches known digests", function()
    assert.equals("a9993e364706816aba3e25717850c26c9cd0d89d", hex(sha1.binary("abc")))
    assert.equals("da39a3ee5e6b4b0d3255bfef95601890afd80709", hex(sha1.binary("")))
    assert.equals(
      "84983e441c3bd26ebaae4aa1f95129e5e54670f1",
      hex(sha1.binary("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"))
    )
  end)

  it("computes the RFC 6455 Sec-WebSocket-Accept", function()
    local key = "dGhlIHNhbXBsZSBub25jZQ=="
    local guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
    assert.equals("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", vim.base64.encode(sha1.binary(key .. guid)))
  end)
end)
