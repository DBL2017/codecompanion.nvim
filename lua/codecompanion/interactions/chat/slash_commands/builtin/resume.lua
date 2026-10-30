local config = require("codecompanion.config")
local picker = require("codecompanion.providers.slash_commands.picker")
local sessions = require("codecompanion.interactions.chat.sessions")
local storage = require("codecompanion.interactions.chat.sessions.storage")
local utils = require("codecompanion.utils")

local CONSTANTS = {
  NAME = "Resume",
  PROMPT_HTTP = "Restore Session",
  PROMPT_ACP = "Resume Session",
  EMPTY_HTTP = "No saved sessions found",
  EMPTY_ACP = "No previous sessions found",
}

---@class CodeCompanion.SlashCommand.Resume: CodeCompanion.SlashCommand
local SlashCommand = {}

---@param args CodeCompanion.SlashCommand
function SlashCommand.new(args)
  local self = setmetatable({
    Chat = args.Chat,
    config = args.config,
    context = args.context,
  }, { __index = SlashCommand })

  return self
end

---Is the slash command enabled?
---@param chat CodeCompanion.Chat
---@return boolean,string
function SlashCommand.enabled(chat)
  -- HTTP chats resume from the sessions we persist ourselves
  if not chat.acp_connection then
    return true, ""
  end

  if not chat.acp_connection:can_list_sessions() then
    return false, "This agent does not support listing sessions"
  end

  if not chat.acp_connection:can_load_session() then
    return false, "This agent does not support loading sessions"
  end

  return true, ""
end

---@param chat CodeCompanion.Chat
---@return boolean
local function has_user_messages(chat)
  return vim.iter(chat.messages):any(function(message)
    return message.role == config.constants.USER_ROLE and message.content ~= ""
  end)
end

---Pick the provider the user configured for this slash command
---@param self CodeCompanion.SlashCommand.Resume
---@param providers table<string, fun(SlashCommand: CodeCompanion.SlashCommand)>
---@return nil
local function use_provider(self, providers)
  local name = self.config.opts and self.config.opts.provider or "default"
  local pick = providers[name] or providers["default"]
  return pick(self)
end

---HTTP chats: restore a persisted session into a new chat buffer
---@return nil
function SlashCommand:restore_http()
  local Chat = self.Chat
  local resumed = false

  local providers = picker.build_list_pickers({
    prompt = CONSTANTS.PROMPT_HTTP,
    empty_message = CONSTANTS.EMPTY_HTTP,
    preview = true,
    items = function()
      return vim.tbl_map(function(session)
        return {
          name = session.meta.title or session.stem,
          description = session.meta.saved_at and "(" .. utils.make_relative(session.meta.saved_at) .. " ago)" or "",
          stem = session.stem,
          path = storage.path(session.stem, "ui"),
        }
      end, sessions.list())
    end,
    output = function(_, item)
      if resumed or not item or not item.stem then
        return
      end
      resumed = true
      sessions.load(item.stem)
      if not has_user_messages(Chat) then
        Chat:close()
      end
    end,
  })

  return use_provider(self, providers)
end

---ACP chats: resume a session reported by the agent
---@param acp_sessions table[] The SessionInfo list, fetched synchronously
---@return nil
function SlashCommand:resume_acp(acp_sessions)
  local Chat = self.Chat
  local resumed = false

  local providers = picker.build_list_pickers({
    prompt = CONSTANTS.PROMPT_ACP,
    empty_message = CONSTANTS.EMPTY_ACP,
    preview = false,
    items = function()
      return vim.tbl_map(function(session)
        local ts = session.updatedAt and utils.timestamp_from_iso(session.updatedAt)
        return {
          name = session.title or session.sessionId,
          description = ts and "(" .. utils.make_relative(ts) .. ")" or session.sessionId,
          session = session,
        }
      end, acp_sessions)
    end,
    output = function(_, item)
      local selected = item and item.session
      if resumed or not selected then
        return
      end
      resumed = true

      -- Collect all session updates during the synchronous load
      local updates = {}
      local ok = Chat.acp_connection:load_session(selected.sessionId, {
        on_session_update = function(update)
          table.insert(updates, update)
        end,
      })

      if not ok then
        return utils.notify("Failed to load session", vim.log.levels.ERROR)
      end

      local acp_commands = require("codecompanion.interactions.chat.acp.commands")
      acp_commands.link_buffer_to_session(Chat.bufnr, Chat.acp_connection.session_id)

      require("codecompanion.interactions.chat.acp.render").restore_session(Chat, updates)

      if selected.title then
        Chat:set_title(selected.title)
      end

      utils.fire("ACPChatRestored", {
        bufnr = Chat.bufnr,
        id = Chat.id,
        session_id = Chat.acp_connection.session_id,
        title = Chat.title,
      })

      utils.notify("Resumed session: " .. (selected.title or selected.sessionId), vim.log.levels.INFO)
    end,
  })

  return use_provider(self, providers)
end

---Execute the slash command
---@return nil
function SlashCommand:execute()
  local Chat = self.Chat

  if not Chat.acp_connection then
    return self:restore_http()
  end

  if Chat.cycle > 1 then
    return utils.notify("The /resume command must be called before submitting any messages", vim.log.levels.WARN)
  end

  local acp_sessions = Chat.acp_connection:session_list({
    max_sessions = (self.config.opts and self.config.opts.max_sessions) or 500,
  })

  if #acp_sessions == 0 then
    return utils.notify(CONSTANTS.EMPTY_ACP, vim.log.levels.INFO)
  end

  return self:resume_acp(acp_sessions)
end

return SlashCommand
