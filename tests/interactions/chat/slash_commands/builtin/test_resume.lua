local h = require("tests.helpers")

local child = MiniTest.new_child_neovim()

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      h.child_start(child)
      child.lua([[
        h = require("tests.helpers")
        chat = h.setup_chat_buffer()
        chat.messages = { { role = "user", content = "existing message" } }

        loaded_session = nil
        local sessions = require("codecompanion.interactions.chat.sessions")
        sessions.list = function()
          return { { stem = "session", meta = { title = "Saved session" } } }
        end
        sessions.load = function(stem)
          loaded_session = stem
        end

        vim.ui.select = function(items, opts, on_choice)
          selected_prompt = opts.prompt
          on_choice(items[1])
        end
      ]])
    end,
    post_once = child.stop,
  },
})

T["Resume"] = MiniTest.new_set()

T["Resume"]["restores a saved HTTP session with the default picker"] = function()
  local result = child.lua([[
    local SlashCommand = require("codecompanion.interactions.chat.slash_commands.builtin.resume")
    SlashCommand.new({ Chat = chat, config = { opts = { provider = "default" } }, context = {} }):execute()
    return { loaded_session = loaded_session, prompt = selected_prompt }
  ]])

  h.eq("session", result.loaded_session)
  h.eq("Restore Session", result.prompt)
end

T["Resume"]["uses the configured picker"] = function()
  local loaded_session = child.lua([[
    package.loaded["codecompanion.providers.slash_commands.picker"] = {
      build_list_pickers = function(opts)
        return {
          test_provider = function(SlashCommand)
            opts.output(SlashCommand, opts.items()[1])
          end,
        }
      end,
    }
    package.loaded["codecompanion.interactions.chat.slash_commands.builtin.resume"] = nil

    local SlashCommand = require("codecompanion.interactions.chat.slash_commands.builtin.resume")
    SlashCommand.new({ Chat = chat, config = { opts = { provider = "test_provider" } }, context = {} }):execute()
    return loaded_session
  ]])

  h.eq("session", loaded_session)
end

return T
