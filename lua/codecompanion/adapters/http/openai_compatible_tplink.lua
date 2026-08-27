--[[
PLEASE NOTE: This adapter is not supported by CodeCompanion.nvim.
It is simply provided as an example for how you can connect an OpenAI compatible endpoint
to CodeCompanion via an adapter. Send any questions or queries to the discussions.
--]]

local Curl = require("plenary.curl")
local config = require("codecompanion.config")
local log = require("codecompanion.utils.log")
local openai = require("codecompanion.adapters.http.openai")
local tags = require("codecompanion.interactions.shared.tags")
local adapter_utils = require("codecompanion.adapters.utils")

local _cache_expires
local _cached_models

---Return the cached models
---@params opts? table
local function models(opts)
    if opts and opts.last then
        return _cached_models[1]
    end
    return _cached_models
end

---Get a list of available OpenAI compatible models
---@params self CodeCompanion.Adapter
---@params opts? table
---@return table
local function get_models(self, opts)
    if _cached_models and _cache_expires and _cache_expires > os.time() then
        return models(opts)
    end

    _cached_models = {}

    local adapter = require("codecompanion.adapters").resolve(self)
    if not adapter then
        log:error("Could not resolve OpenAI compatible adapter in the `get_models` function")
        return {}
    end

    adapter_utils.get_env_vars(adapter, { timeout = config.adapters.opts.cmd_timeout })
    local url = adapter.env_replaced.url .. adapter.env_replaced.models_endpoint

    local headers = adapter_utils.set_env_vars(adapter, adapter.headers) or {}

    local ok, response, json

    ok, response = pcall(function()
        return Curl.get(url, {
            sync = true,
            headers = headers,
            insecure = config.adapters.http.opts.allow_insecure,
            proxy = config.adapters.http.opts.proxy,
        })
    end)
    if not ok then
        log:error("Could not get the OpenAI compatible models from " .. url .. ".\nError: %s", response)
        return {}
    end

    ok, json = pcall(vim.json.decode, response.body)
    if not ok then
        log:error("Could not parse the response from " .. url)
        return {}
    end

    for _, model in ipairs(json.data) do
        table.insert(_cached_models, model.id)
    end

    _cache_expires = adapter_utils.cache_expiry(config.adapters.http.opts.cache_models_for)

    return models(opts)
end

---@class CodeCompanion.HTTPAdapter.OpenAICompatible: CodeCompanion.HTTPAdapter
return {
    name = "openai_compatible_tplink",
    formatted_name = "OpenAI Compatible TPLink",
    roles = {
        llm = "assistant",
        user = "user",
    },
    opts = {
        stream = true,
        tools = true,
        vision = true,
    },
    features = {
        text = true,
        tokens = true,
    },
    url = "${url}${chat_url}",
    env = {
        api_key = "OPENAI_API_KEY",
        url = "http://localhost:11434",
        chat_url = "/v1/chat/completions",
        models_endpoint = "/v1/models",
    },
    headers = {
        ["Content-Type"] = "application/json",
        Authorization = "Bearer ${api_key}",
    },
    handlers = {
        ---@param self CodeCompanion.HTTPAdapter
        ---@return boolean
        setup = function(self)
            if self.opts and self.opts.stream then
                self.parameters.stream = true
                self.parameters.stream_options = { include_usage = true }
            end
            return true
        end,

        tokens = function(self, data)
            return openai.handlers.tokens(self, data)
        end,
        form_parameters = function(self, params, messages)
            return openai.handlers.form_parameters(self, params, messages)
        end,
        form_messages = function(self, messages)
            local model = self.schema.model.default
            if type(model) == "function" then
                model = model(self)
            end

            messages = vim.iter(messages)
                :map(function(m)
                    if vim.startswith(model, "o1") and m.role == "system" then
                        m.role = self.roles.user
                    end

                    -- Ensure tool_calls are clean
                    local tool_calls = nil
                    if m.tools and m.tools.calls then
                        tool_calls = vim.iter(m.tools.calls)
                            :map(function(tool_call)
                                return {
                                    id = tool_call.id,
                                    ["function"] = tool_call["function"],
                                    type = tool_call.type,
                                    -- Include a _meta field to hold everything else
                                }
                            end)
                            :totable()
                    end

                    -- Process any images
                    if m._meta and m._meta.tag == tags.IMAGE and m.context and m.context.mimetype then
                        if self.opts and self.opts.vision then
                            m.content = {
                                {
                                    type = "image_url",
                                    image_url = {
                                        url = string.format("data:%s;base64,%s", m.context.mimetype, m.content),
                                    },
                                },
                            }
                        else
                            -- Remove the message if vision is not supported
                            return nil
                        end
                    end

                    -- Process any documents
                    -- NOTE: Only support PDFs for now
                    if
                        m._meta
                        and m._meta.tag == tags.DOCUMENT
                        and m._meta.filetype == "pdf"
                        and m.context
                        and m.context.mimetype
                    then
                        if self.opts and self.opts.documents then
                            m.content = {
                                {
                                    type = "file",
                                    file = {
                                        filename = vim.fn.fnamemodify(m.context.path, ":t"),
                                        file_data = string.format("data:%s;base64,%s", m.context.mimetype, m.content),
                                    },
                                },
                            }
                        else
                            return log:warn(
                                "The `%s` model does not support documents so has been removed from the request",
                                self.formatted_name
                            )
                        end
                    end

                    local result = {
                        role = m.role,
                        content = m.content,
                        tool_calls = tool_calls,
                        tool_call_id = m.tools and m.tools.call_id or nil,
                    }

                    -- Adapter's like Copilot have reasoning fields that must be preserved
                    if m.reasoning then
                        result.reasoning = m.reasoning
                    end

                    return result
                end)
                :totable()
            local system = nil
            local merged = {}
            for _, msg in ipairs(messages) do
                if msg.role == "system" and msg.content and type(msg.content) == "string" then
                    if not system then
                        system = msg
                    else
                        system.content = system.content .. "\n\n" .. (vim.trim(msg.content) or msg.content)
                    end
                else
                    table.insert(merged, msg)
                end
            end
            if system then
                table.insert(merged, 1, system)
            end

            return { messages = merged }
        end,
        form_tools = function(self, tools)
            return openai.handlers.form_tools(self, tools)
        end,
        chat_output = function(self, data, tools)
            return openai.handlers.chat_output(self, data, tools)
        end,
        inline_output = function(self, data, context)
            return openai.handlers.inline_output(self, data, context)
        end,
        tools = {
            format_tool_calls = function(self, tools)
                return openai.handlers.tools.format_tool_calls(self, tools)
            end,
            output_response = function(self, tool_call, output)
                return openai.handlers.tools.output_response(self, tool_call, output)
            end,
        },
        on_exit = function(self, data)
            return openai.handlers.on_exit(self, data)
        end,
    },
    schema = {
        ---@type CodeCompanion.Schema
        model = {
            order = 1,
            mapping = "parameters",
            type = "enum",
            desc = "ID of the model to use. See the model endpoint compatibility table for details on which models work with the Chat API.",
            default = function(self)
                return get_models(self, { last = true })
            end,
            choices = function(self)
                return get_models(self)
            end,
        },
    },
}
