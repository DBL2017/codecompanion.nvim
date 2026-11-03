local h = require("tests.helpers")
local new_set = MiniTest.new_set

local child = MiniTest.new_child_neovim()
local T = new_set({
  hooks = {
    pre_case = function()
      h.child_start(child)
      child.lua([[
        h = require("tests.helpers")
        _G.chat = h.setup_chat_buffer()
        require("codecompanion.config").display.chat.stream_interval = 25
      ]])
    end,
    post_case = function()
      child.lua([[h.teardown_chat_buffer()]])
    end,
    post_once = child.stop,
  },
})

T["ACPRender"] = new_set()

T["ACPRender"]["flushes restored LLM messages before preparing input"] = function()
  local result = child.lua([[
    local render = require("codecompanion.interactions.chat.acp.render")
    render.restore_session(_G.chat, {
      {
        sessionUpdate = "user_message_chunk",
        content = { type = "text", text = "Question" },
      },
      {
        sessionUpdate = "agent_message_chunk",
        content = { type = "text", text = "Answer" },
      },
    })

    vim.wait(75, function() return false end, 5)

    return {
      last_role = _G.chat._last_role,
      modifiable = vim.bo[_G.chat.bufnr].modifiable,
      lines = table.concat(vim.api.nvim_buf_get_lines(_G.chat.bufnr, 0, -1, false), "\\n"),
    }
  ]])

  h.eq("user", result.last_role)
  h.is_true(result.modifiable)
  h.is_true(result.lines:find("Question", 1, true) ~= nil)
  h.is_true(result.lines:find("Answer", 1, true) ~= nil)
end

return T
